import { Controller } from "@hotwired/stimulus"
import { keepNewerReactions, reactionsVersion as version } from "coplan/comment_reactions"

// Reaction chips under a comment. The server renders one copy for every
// viewer (broadcasts have no current_user), listing who reacted; this
// controller marks the viewer's own reactions as pressed and names them
// "You".
//
// Each chip carries the server's confirmed reactors. Choices still on
// their way to the server are kept here, per comment, and drawn on top of
// whatever the server last sent, so a broadcast or response that lands
// mid-flight never undoes a newer click, and a failed request falls back
// to the confirmed state. Requests for one comment run in order.
const queues = new Map()
const pending = new Map()
const focusAfterReplace = new Map()
let sequence = 0
let application
const NAME_LIMIT = 10
const IDENTIFIER = "coplan--comment-reactions"
const COMMENT_ID = `data-${IDENTIFIER}-comment-id-value`

function enqueue(key, task) {
  const run = (queues.get(key) || Promise.resolve()).catch(() => {}).then(task)
  queues.set(key, run)
  run.catch(() => {}).finally(() => { if (queues.get(key) === run) queues.delete(key) })
  return run
}

function choicesFor(commentId) {
  if (!pending.has(commentId)) pending.set(commentId, new Map())
  return pending.get(commentId)
}

function settle(commentId, kind, seq) {
  const choices = pending.get(commentId)
  if (choices?.get(kind)?.seq === seq) choices.delete(kind)
  if (choices?.size === 0) pending.delete(commentId)
}

// Redraws every copy of a comment's reactions, including cloned
// discussions that don't receive Turbo Stream updates themselves.
function redraw(commentId) {
  document.querySelectorAll(`[${COMMENT_ID}="${CSS.escape(commentId)}"]`).forEach(element => {
    application?.getControllerForElementAndIdentifier(element, IDENTIFIER)?.display()
  })
}

// Responses and broadcasts from concurrent changes can arrive in any
// order. Turbo renders a stream a frame after announcing it, by
// which time another may have landed, so the checks run at render time.
document.addEventListener("turbo:before-stream-render", event => {
  const stream = event.target
  const render = event.detail.render
  event.detail.render = async streamElement => {
    if (keepCurrentReactions(stream)) await render(streamElement)
  }
})

// Returns false to skip the stream.
function keepCurrentReactions(stream) {
  const content = stream.templateElement?.content
  if (!content) return true
  const current = document.getElementById(stream.getAttribute("target") || "")
  if (current?.matches(".comment-reactions")) {
    // The same version shows the same reactions. A response skipped here
    // may still have settled a choice, so redraw without it.
    if (version(content.firstElementChild) <= version(current)) {
      redraw(current.getAttribute(COMMENT_ID))
      return false
    }
    rememberFocus(current)
    return true
  }
  keepNewerReactions(content)
  return true
}

// Notes which control has focus so the replacement can take it back.
function rememberFocus(reactions) {
  const focused = document.activeElement
  if (!reactions.contains(focused)) return
  focusAfterReplace.set(reactions.getAttribute(COMMENT_ID), {
    kind: focused.closest(".comment-reaction, .comment-reactions__option")?.dataset.kind,
    inPicker: Boolean(focused.closest(".comment-reactions__picker"))
  })
}

export default class extends Controller {
  static values = { url: String, commentId: String }
  static targets = ["chip", "add", "picker", "option", "tooltip", "chipTemplate"]

  connect() {
    application = this.application
    this.me = document.querySelector("meta[name='coplan-current-user-id']")?.content || ""
    this.addTarget.hidden = !this.me
    // A copy of the chips made while the picker was open says so.
    this.addTarget.setAttribute("aria-expanded", this.pickerTarget.matches(":popover-open"))
    this.display()
    this.restoreFocus()
  }

  disconnect() {
    this.hideTooltip()
    this.closePicker()
    this.stopClosingOnMove()
  }

  toggle(event) {
    const chip = event.currentTarget
    this.react(chip.dataset.kind, chip.getAttribute("aria-pressed") !== "true")
    if (chip.isConnected && chip.matches(":hover, :focus-visible")) this.showTooltip({ currentTarget: chip })
  }

  pick(event) {
    const option = event.currentTarget
    this.closePicker()
    this.addTarget.focus({ preventScroll: true })
    this.react(option.dataset.kind, option.getAttribute("aria-pressed") !== "true")
  }

  react(kind, reacted) {
    if (!this.me) return
    const commentId = this.commentIdValue
    const url = this.urlValue
    const seq = ++sequence
    choicesFor(commentId).set(kind, { reacted, seq })
    redraw(commentId)

    const body = new FormData()
    body.append("kind", kind)
    body.append("reacted", reacted)
    enqueue(commentId, async () => {
      const response = await fetch(url, {
        method: "PATCH", body,
        headers: { "Accept": "text/vnd.turbo-stream.html", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content }
      })
      const type = response.headers.get("Content-Type") || ""
      // A signed-out request may be redirected to an HTML sign-in page.
      if (response.ok && type.startsWith("text/vnd.turbo-stream.html")) return response.text()
      // Only this endpoint's own refusals are plain text meant for people.
      const reason = response.status === 422 && type.startsWith("text/plain") ? await response.text() : ""
      throw Object.assign(new Error(reason), { reason })
    }).then(html => {
      settle(commentId, kind, seq)
      window.Turbo.renderStreamMessage(html)
    }).catch(error => {
      settle(commentId, kind, seq)
      redraw(commentId)
      this.toast(error.reason || "Couldn't save your reaction. Please try again.")
    })
  }

  // A keyboard user keeps focus on the same chip (or on the add button if
  // the chip went away), or keeps the picker open, when the server's copy
  // replaces these controls.
  restoreFocus() {
    // Set by the cloned-discussion panel when it rebuilds this copy.
    const reopen = this.element.dataset.reopenPicker
    if (reopen !== undefined) {
      delete this.element.dataset.reopenPicker
      if (this.showPicker()) (this.optionFor(reopen) || this.optionTargets[0])?.focus({ preventScroll: true })
      return
    }
    const saved = focusAfterReplace.get(this.commentIdValue)
    if (!saved || !this.element.isConnected) return
    focusAfterReplace.delete(this.commentIdValue)
    if (saved.inPicker && this.showPicker()) {
      this.optionFor(saved.kind)?.focus({ preventScroll: true })
      return
    }
    const chip = saved.kind && this.chipFor(saved.kind)
    const target = chip && !chip.hidden ? chip : this.addTarget
    if (!target.hidden) target.focus({ preventScroll: true })
  }

  display() {
    const choices = pending.get(this.commentIdValue)
    this.optionTargets.forEach(option => {
      const kind = option.dataset.kind
      let chip = this.chipFor(kind)
      let reactors = chip ? this.confirmedReactors(chip) : []
      const choice = choices?.get(kind)
      if (choice) {
        reactors = reactors.filter(reactor => reactor.id !== this.me)
        if (choice.reacted) reactors.push({ id: this.me, name: "" })
      }
      if (!chip && !reactors.length) return
      chip ||= this.buildChip(kind)
      // Hidden rather than removed, so the confirmed reactors survive if
      // the request that emptied this chip fails. Focus moves first, or the
      // browser would drop it with the chip.
      if (!reactors.length && chip.contains(document.activeElement)) this.addTarget.focus({ preventScroll: true })
      chip.hidden = !reactors.length
      if (chip.hidden && chip === this.tooltipChip) this.hideTooltip()
      chip.dataset.reactors = JSON.stringify(reactors)
      const count = chip.querySelector(".comment-reaction__count")
      if (count.textContent !== String(reactors.length)) count.textContent = reactors.length
    })
    this.refresh()
  }

  refresh() {
    this.chipTargets.forEach(chip => {
      const reactors = this.reactors(chip)
      chip.setAttribute("aria-pressed", reactors.some(reactor => reactor.id === this.me))
      chip.setAttribute("aria-label", this.sentence(reactors, this.optionFor(chip.dataset.kind)?.dataset.label))
    })
    this.optionTargets.forEach(option => {
      option.setAttribute("aria-pressed", this.chipFor(option.dataset.kind)?.getAttribute("aria-pressed") === "true")
    })
  }

  showTooltip(event) {
    const chip = event.currentTarget
    if (!chip.isConnected || chip.hidden) return
    this.tooltipChip = chip
    const tooltip = this.tooltipTarget
    // The text lives in an attribute (rendered with CSS) so hovering never
    // changes the thread markup that other controllers observe.
    tooltip.dataset.text = this.sentence(this.reactors(chip), this.optionFor(chip.dataset.kind)?.dataset.emoji)
    try { tooltip.showPopover() } catch {}
    this.place(tooltip, chip, { above: true })
  }

  hideTooltip() {
    this.tooltipChip = null
    if (!this.hasTooltipTarget) return
    try { this.tooltipTarget.hidePopover() } catch {}
  }

  // Light dismiss runs before the click, so remember whether this press
  // started with the picker open; otherwise the click would reopen it. A
  // press can end without a click, so only a pointer click (detail > 0)
  // reads what was remembered.
  notePicker() {
    this.pickerWasOpen = this.pickerTarget.matches(":popover-open")
  }

  openPicker(event) {
    const wasOpen = (event?.detail > 0 && this.pickerWasOpen) || this.pickerTarget.matches(":popover-open")
    this.pickerWasOpen = false
    if (wasOpen) {
      this.closePicker()
      return
    }
    if (this.showPicker()) this.optionTargets[0]?.focus({ preventScroll: true })
  }

  showPicker() {
    this.hideTooltip()
    try { this.pickerTarget.showPopover() } catch { return false }
    this.place(this.pickerTarget, this.addTarget, { above: false })
    this.closeOnMove()
    return true
  }

  closePicker() {
    if (!this.hasPickerTarget) return
    try { this.pickerTarget.hidePopover() } catch {}
  }

  pickerToggled(event) {
    const open = event.newState === "open"
    this.addTarget.setAttribute("aria-expanded", open)
    if (!open) this.stopClosingOnMove()
    if (!open && this.pickerTarget.contains(document.activeElement)) this.addTarget.focus({ preventScroll: true })
  }

  // The picker is fixed in place, so any scroll (including one inside a
  // comment window, which doesn't bubble) or resize leaves it behind.
  closeOnMove() {
    this.moved ||= () => this.closePicker()
    window.addEventListener("scroll", this.moved, { capture: true, passive: true })
    window.addEventListener("resize", this.moved)
  }

  stopClosingOnMove() {
    if (!this.moved) return
    window.removeEventListener("scroll", this.moved, { capture: true })
    window.removeEventListener("resize", this.moved)
  }

  buildChip(kind) {
    const option = this.optionFor(kind)
    const chip = this.chipTemplateTarget.content.firstElementChild.cloneNode(true)
    chip.dataset.kind = kind
    chip.querySelector(".comment-reaction__emoji").textContent = option.dataset.emoji
    const order = this.optionTargets.map(target => target.dataset.kind)
    const next = this.chipTargets.find(other => order.indexOf(other.dataset.kind) > order.indexOf(kind))
    this.element.insertBefore(chip, next || this.addTarget)
    return chip
  }

  sentence(reactors, reaction) {
    const names = reactors
      .slice()
      .sort((a, b) => (b.id === this.me) - (a.id === this.me))
      .map(reactor => reactor.id === this.me ? "You" : reactor.name)
    const shown = names.slice(0, NAME_LIMIT).join(", ")
    const others = names.length - NAME_LIMIT
    const who = others > 0 ? `${shown} and ${others} ${others === 1 ? "other" : "others"}` : shown
    return `${who} reacted with ${reaction}`
  }

  place(popover, anchor, { above }) {
    const gap = 6
    const margin = 8
    const target = anchor.getBoundingClientRect()
    const box = popover.getBoundingClientRect()
    const fitsAbove = target.top - box.height - gap >= margin
    const fitsBelow = target.bottom + box.height + gap <= window.innerHeight - margin
    const top = (above ? fitsAbove || !fitsBelow : !fitsBelow && fitsAbove)
      ? target.top - box.height - gap
      : target.bottom + gap
    const left = Math.min(Math.max(margin, target.left + target.width / 2 - box.width / 2), window.innerWidth - box.width - margin)
    popover.style.top = `${Math.max(margin, top)}px`
    popover.style.left = `${Math.max(margin, left)}px`
  }

  chipFor(kind) {
    return this.chipTargets.find(chip => chip.dataset.kind === kind)
  }

  optionFor(kind) {
    return this.optionTargets.find(option => option.dataset.kind === kind)
  }

  reactors(chip) {
    return this.parse(chip.dataset.reactors)
  }

  confirmedReactors(chip) {
    return this.parse(chip.dataset.confirmedReactors)
  }

  parse(json) {
    try { return JSON.parse(json || "[]") } catch { return [] }
  }

  toast(message) {
    const container = document.getElementById("coplan-toasts")
    if (!container) return
    const toast = document.createElement("div")
    toast.className = "flash flash--alert toasts__toast"
    toast.setAttribute("role", "status")
    toast.dataset.controller = "coplan--toast"
    toast.textContent = message
    container.appendChild(toast)
  }
}
