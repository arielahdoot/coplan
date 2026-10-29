import { Controller } from "@hotwired/stimulus"

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
const NAME_LIMIT = 10

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

export default class extends Controller {
  static values = { url: String, commentId: String }
  static targets = ["chip", "add", "picker", "option", "tooltip", "chipTemplate"]

  connect() {
    this.me = document.querySelector("meta[name='coplan-current-user-id']")?.content || ""
    this.addTarget.hidden = !this.me
    this.display()
    this.restoreFocus()
  }

  disconnect() {
    this.hideTooltip()
    this.closePicker()
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
    this.displayAll(commentId)

    const body = new FormData()
    body.append("kind", kind)
    body.append("reacted", reacted)
    enqueue(commentId, async () => {
      const response = await fetch(url, {
        method: "PATCH", body,
        headers: { "Accept": "text/vnd.turbo-stream.html", "X-CSRF-Token": document.querySelector('meta[name="csrf-token"]')?.content }
      })
      if (!response.ok) throw new Error(response.status === 422 ? await response.text() : "")
      return response.text()
    }).then(html => {
      settle(commentId, kind, seq)
      window.Turbo.renderStreamMessage(html)
    }).catch(error => {
      settle(commentId, kind, seq)
      this.displayAll(commentId)
      this.toast(error.message || "Couldn't save your reaction. Please try again.")
    })
  }

  // Responses and broadcasts from concurrent changes can arrive in any
  // order. Skip a replacement older than the chips already on screen.
  beforeStream(event) {
    const stream = event.target
    if (!this.element.id || stream.getAttribute("target") !== this.element.id) return
    const incoming = stream.templateContent?.firstElementChild
    if (Number(incoming?.dataset.version) < Number(this.element.dataset.version)) {
      event.preventDefault()
      return
    }
    const focused = document.activeElement
    if (!this.element.contains(focused)) return
    const chip = focused.closest(".comment-reaction")
    focusAfterReplace.set(this.commentIdValue, chip ? chip.dataset.kind : "add")
  }

  // A keyboard user who just toggled a chip keeps focus on it (or on the
  // add button if the chip went away) when the server's copy replaces it.
  restoreFocus() {
    const kind = focusAfterReplace.get(this.commentIdValue)
    if (!kind || !this.element.isConnected) return
    focusAfterReplace.delete(this.commentIdValue)
    const chip = this.chipFor(kind)
    const target = chip && !chip.hidden ? chip : this.addTarget
    if (!target.hidden) target.focus({ preventScroll: true })
  }

  // Redraws every copy of this comment's reactions, including cloned
  // discussions that don't receive Turbo Stream updates themselves.
  displayAll(commentId) {
    document.querySelectorAll(`[data-coplan--comment-reactions-comment-id-value="${CSS.escape(commentId)}"]`).forEach(element => {
      this.application.getControllerForElementAndIdentifier(element, this.identifier)?.display()
    })
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
      // the request that emptied this chip fails.
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
    if (!chip.isConnected) return
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
  // started with the picker open; otherwise the click would reopen it.
  notePicker() {
    this.pickerWasOpen = this.pickerTarget.matches(":popover-open")
  }

  openPicker() {
    const wasOpen = this.pickerWasOpen || this.pickerTarget.matches(":popover-open")
    this.pickerWasOpen = false
    if (wasOpen) {
      this.closePicker()
      return
    }
    this.hideTooltip()
    try { this.pickerTarget.showPopover() } catch { return }
    this.place(this.pickerTarget, this.addTarget, { above: false })
    this.optionTargets[0]?.focus({ preventScroll: true })
  }

  closePicker() {
    if (!this.hasPickerTarget) return
    try { this.pickerTarget.hidePopover() } catch {}
  }

  pickerToggled(event) {
    const open = event.newState === "open"
    this.addTarget.setAttribute("aria-expanded", open)
    if (!open && this.pickerTarget.contains(document.activeElement)) this.addTarget.focus({ preventScroll: true })
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
