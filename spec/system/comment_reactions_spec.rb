require "rails_helper"

RSpec.describe "Comment reactions", type: :system do
  let(:viewer) { create(:coplan_user, email: "reactions-viewer@example.com", name: "Hampton") }
  let(:sam) { create(:coplan_user, email: "reactions-sam@example.com", name: "Sam Chen") }
  let(:content) do
    <<~MARKDOWN
      # Reaction plan

      The cache keeps results warm between deploys.

      | Name | Status |
      |---|---|
      | Receipt | queued |
    MARKDOWN
  end
  let(:plan) do
    CoPlan::Plan.create!(title: "Reaction plan", created_by_user: viewer).tap do |p|
      version = create(:plan_version, plan: p, revision: 1, content_markdown: content)
      p.update!(current_plan_version: version, current_revision: 1)
    end
  end
  let!(:thread_record) do
    plan.comment_threads.create!(plan_version: plan.current_plan_version, anchor_text: "keeps results warm",
      anchor_occurrence: 1, created_by_user: sam, status: "open")
  end
  let!(:comment) do
    thread_record.comments.create!(author_type: "human", author_id: sam.id, body_markdown: "How long do results stay warm?")
  end

  def sign_in(user)
    visit sign_in_path
    fill_in "Email address", with: user.email
    click_button "Sign In"
    expect(page).to have_no_current_path(sign_in_path)
    expect(page).to have_button("Menu")
  end

  def open_thread
    visit plan_page_path(plan)
    find("mark[data-thread-id='comment_thread_#{thread_record.id}']").click
    find(".thread-popover:popover-open")
  end

  def wait_for(timeout: Capybara.default_max_wait_time)
    Timeout.timeout(timeout) { sleep 0.05 until yield }
  end

  def have_reaction(kind, count:, pressed:)
    have_css(".comment-reaction[data-kind='#{kind}'][aria-pressed='#{pressed}'] .comment-reaction__count", exact_text: count.to_s)
  end

  # A click can be lost while the server's copy replaces the chips (the
  # press and release land on different elements), so wait for that copy.
  def have_saved_reactions
    have_css(".comment-reactions[data-version='#{comment.reload.reactions_version}']")
  end

  def chip(scope, emoji)
    scope.find(".comment-reaction", text: emoji)
  end

  before { sign_in(viewer) }

  it "marks the viewer's own reactions as pressed and names who reacted" do
    create(:comment_reaction, comment: comment, user: viewer, kind: "thumbs_up")
    create(:comment_reaction, comment: comment, user: sam, kind: "thumbs_up")
    create(:comment_reaction, comment: comment, user: sam, kind: "tada")

    popover = open_thread

    expect(popover).to have_css(".comment-reaction[aria-pressed='true']", text: "👍")
    expect(popover).to have_css(".comment-reaction[aria-pressed='false']", text: "🎉")
    expect(chip(popover, "👍")[:"aria-label"]).to eq("You, Sam Chen reacted with thumbs up")
    expect(chip(popover, "🎉")[:"aria-label"]).to eq("Sam Chen reacted with party popper")

    chip(popover, "🎉").hover
    expect(page).to have_css(".comment-reactions__tooltip:popover-open[data-text='Sam Chen reacted with 🎉']", visible: :all)
    chip(popover, "👍").hover
    expect(page).to have_css(".comment-reactions__tooltip:popover-open[data-text='You, Sam Chen reacted with 👍']", visible: :all)
  end

  it "adds and removes reactions in place without reloading" do
    create(:comment_reaction, comment: comment, user: sam, kind: "tada")
    popover = open_thread
    page.execute_script("window.reactionsPageMarker = true")

    popover.find(".comment-reactions__add").click
    expect(page).to have_css(".comment-reactions__picker:popover-open")
    find(".comment-reactions__picker:popover-open .comment-reactions__option", text: "🚀").click

    expect(popover).to have_reaction("rocket", count: 1, pressed: true)
    expect(page).to have_no_css(".comment-reactions__picker:popover-open")
    wait_for { comment.reactions.where(user: viewer, kind: "rocket").exists? }
    expect(popover).to have_saved_reactions

    chip(popover, "🎉").click
    expect(popover).to have_reaction("tada", count: 2, pressed: true)
    wait_for { comment.reactions.where(kind: "tada").count == 2 }
    expect(popover).to have_saved_reactions

    chip(popover, "🎉").click
    expect(popover).to have_reaction("tada", count: 1, pressed: false)
    chip(popover, "🚀").click
    expect(popover).to have_no_css(".comment-reaction", text: "🚀")
    wait_for { comment.reactions.where(user: viewer).count == 0 }

    expect(page).to have_css(".thread-popover:popover-open")
    expect(page.evaluate_script("window.reactionsPageMarker")).to be(true)
  end

  it "keeps keyboard focus on a chip after the server's copy replaces it" do
    create(:comment_reaction, comment: comment, user: sam, kind: "tada")
    popover = open_thread

    chip(popover, "🎉").send_keys(:enter)
    expect(popover).to have_reaction("tada", count: 2, pressed: true)
    wait_for { comment.reactions.where(user: viewer, kind: "tada").exists? }
    expect(page).to have_css(".comment-reaction[data-kind='tada']:focus")
    expect(page).to have_css(".comment-reactions__tooltip:popover-open[data-text='You, Sam Chen reacted with 🎉']", visible: :all)

    chip(popover, "🎉").send_keys(:enter)
    expect(popover).to have_reaction("tada", count: 1, pressed: false)
    wait_for { !comment.reactions.where(user: viewer).exists? }
    expect(page).to have_css(".comment-reaction[data-kind='tada']:focus")
  end

  it "moves keyboard focus to the add button when removing the last reaction on a chip" do
    create(:comment_reaction, comment: comment, user: viewer, kind: "heart")
    popover = open_thread

    chip(popover, "❤️").send_keys(:enter)
    expect(popover).to have_no_css(".comment-reaction", text: "❤️")
    expect(page).to have_css(".comment-reactions__add:focus")
    wait_for { !comment.reactions.where(user: viewer).exists? }
    expect(page).to have_css(".comment-reactions__add:focus")

    page.driver.browser.action.send_keys(:enter).perform
    expect(page).to have_css(".comment-reactions__picker:popover-open")
  end

  it "falls back to the saved reactions when the server rejects a change" do
    create(:comment_reaction, comment: comment, user: viewer, kind: "heart")
    popover = open_thread
    comment.soft_delete!

    chip(popover, "❤️").click
    popover.find(".comment-reactions__add").click
    find(".comment-reactions__picker:popover-open .comment-reactions__option", text: "👍").click

    expect(page).to have_css(".toasts__toast", text: "You can't react to a deleted comment.")
    expect(popover).to have_reaction("heart", count: 1, pressed: true)
    expect(popover).to have_no_css(".comment-reaction[data-kind='thumbs_up']")
  end

  it "keeps the saved reactions and says so when answered with a sign-in page" do
    create(:comment_reaction, comment: comment, user: viewer, kind: "heart")
    popover = open_thread
    page.execute_script(<<~JS)
      window.fetch = () => Promise.resolve(new Response("<main>Sign in</main>", { headers: { "Content-Type": "text/html" } }))
    JS

    chip(popover, "❤️").click

    expect(page).to have_css(".toasts__toast", text: "Couldn't save your reaction. Please try again.")
    expect(popover).to have_reaction("heart", count: 1, pressed: true)
    expect(comment.reactions.where(user: viewer, kind: "heart")).to exist
  end

  [
    [ "offline", "Promise.reject(new TypeError('Failed to fetch'))" ],
    [ "refused by the framework", "Promise.resolve(new Response('<html>Invalid authenticity token</html>', " \
      "{ status: 422, headers: { 'Content-Type': 'text/html' } }))" ]
  ].each do |situation, response|
    it "shows a plain message when the request fails #{situation}" do
      popover = open_thread
      page.execute_script("window.fetch = () => #{response}")

      popover.find(".comment-reactions__add").click
      find(".comment-reactions__picker:popover-open .comment-reactions__option", text: "👍").click

      expect(page).to have_css(".toasts__toast", exact_text: "Couldn't save your reaction. Please try again.")
      expect(popover).to have_no_css(".comment-reaction", text: "👍")
    end
  end

  it "shows another person's reaction live" do
    popover = open_thread

    reaction = create(:comment_reaction, comment: comment, user: sam, kind: "eyes")
    comment.bump_reactions_version!
    CoPlan::Broadcaster.replace_to(plan, target: ActionView::RecordIdentifier.dom_id(comment, :reactions),
      partial: "coplan/comments/reactions", locals: { comment: reaction.comment.reload })

    expect(popover).to have_reaction("eyes", count: 1, pressed: false)
  end

  it "opens the picker from the keyboard after a press that didn't end in a click" do
    popover = open_thread
    add = popover.find(".comment-reactions__add")
    add.click
    expect(page).to have_css(".comment-reactions__picker:popover-open")

    page.driver.browser.action.move_to(add.native).click_and_hold.move_by(0, -60).release.perform
    expect(page).to have_no_css(".comment-reactions__picker:popover-open")

    add.send_keys(:enter)
    expect(page).to have_css(".comment-reactions__picker:popover-open")
  end

  it "closes the picker when the comment window scrolls" do
    popover = open_thread
    popover.find(".comment-reactions__add").click
    expect(page).to have_css(".comment-reactions__picker:popover-open")

    page.execute_script("document.querySelector('.thread-popover:popover-open .thread-popover__comments').dispatchEvent(new Event('scroll'))")

    expect(page).to have_no_css(".comment-reactions__picker:popover-open")
    expect(page).to have_css(".thread-popover:popover-open")
  end

  it "keeps the picker open when someone else's reaction arrives" do
    popover = open_thread
    popover.find(".comment-reactions__add").click
    expect(page).to have_css(".comment-reactions__picker:popover-open .comment-reactions__option:focus")

    create(:comment_reaction, comment: comment, user: sam, kind: "eyes")
    comment.bump_reactions_version!
    CoPlan::Broadcaster.replace_to(plan, target: ActionView::RecordIdentifier.dom_id(comment, :reactions),
      partial: "coplan/comments/reactions", locals: { comment: comment.reload })

    expect(popover).to have_reaction("eyes", count: 1, pressed: false)
    expect(page).to have_css(".comment-reactions__picker:popover-open .comment-reactions__option:focus")
    expect(page).to have_css(".thread-popover:popover-open")
  end

  it "drops an in-flight choice once answered, even by a snapshot already on screen" do
    popover = open_thread
    target = ActionView::RecordIdentifier.dom_id(comment, :reactions)
    page.execute_script(<<~JS)
      window.fetch = () => new Promise(resolve => { window.answerReaction = body => resolve(new Response(body)) })
    JS

    popover.find(".comment-reactions__add").click
    find(".comment-reactions__picker:popover-open .comment-reactions__option", text: "🚀").click
    expect(popover).to have_reaction("rocket", count: 1, pressed: true)

    comment.bump_reactions_version!
    CoPlan::Broadcaster.replace_to(plan, target: target, partial: "coplan/comments/reactions", locals: { comment: comment.reload })
    expect(popover).to have_css(%(.comment-reactions[data-version="#{comment.reactions_version}"]))
    expect(popover).to have_reaction("rocket", count: 1, pressed: true)

    snapshot = CoPlan::ApplicationController.render(partial: "coplan/comments/reactions", locals: { comment: comment })
    page.execute_script(<<~JS, target, snapshot)
      window.answerReaction(`<turbo-stream action="replace" target="${arguments[0]}"><template>${arguments[1]}</template></turbo-stream>`)
    JS
    expect(popover).to have_no_css(".comment-reaction", text: "🚀")
  end

  it "keeps focus on a new chip while its saved copy arrives" do
    popover = open_thread
    target = ActionView::RecordIdentifier.dom_id(comment, :reactions)
    page.execute_script(<<~JS)
      window.fetch = () => new Promise(resolve => { window.answerReaction = body => resolve(new Response(body, { headers: { "Content-Type": "text/vnd.turbo-stream.html" } })) })
    JS
    popover.find(".comment-reactions__add").click
    find(".comment-reactions__picker:popover-open .comment-reactions__option", text: "🚀").click
    expect(popover).to have_reaction("rocket", count: 1, pressed: true)
    page.execute_script("document.querySelector('.thread-popover:popover-open .comment-reaction[data-kind=rocket]').focus()")

    create(:comment_reaction, comment: comment, user: viewer, kind: "rocket")
    comment.bump_reactions_version!
    saved = CoPlan::ApplicationController.render(partial: "coplan/comments/reactions", locals: { comment: comment.reload })
    page.execute_script(<<~JS, target, saved)
      window.answerReaction(`<turbo-stream action="replace" target="${arguments[0]}"><template>${arguments[1]}</template></turbo-stream>`)
    JS

    expect(popover).to have_css(%(.comment-reactions[data-version="#{comment.reactions_version}"]))
    expect(page).to have_css(".comment-reaction[data-kind='rocket'][aria-pressed='true']:focus")
  end

  it "ignores a replacement older than the chips on screen" do
    popover = open_thread
    target = ActionView::RecordIdentifier.dom_id(comment, :reactions)
    stale = CoPlan::ApplicationController.render(partial: "coplan/comments/reactions", locals: { comment: comment })
    create(:comment_reaction, comment: comment, user: sam, kind: "eyes")
    comment.bump_reactions_version!
    CoPlan::Broadcaster.replace_to(plan, target: target, partial: "coplan/comments/reactions", locals: { comment: comment.reload })
    expect(popover).to have_reaction("eyes", count: 1, pressed: false)

    page.execute_script(<<~JS, target, stale)
      window.Turbo.renderStreamMessage(`<turbo-stream action="replace" target="${arguments[0]}"><template>${arguments[1]}</template></turbo-stream>`)
    JS
    sleep 0.2
    expect(popover).to have_reaction("eyes", count: 1, pressed: false)
  end

  it "keeps newer reactions when an older render of the whole thread arrives" do
    popover = open_thread
    stale_thread = CoPlan::ApplicationController.render(partial: "coplan/comment_threads/thread_popover",
      locals: { thread: thread_record, plan: plan })
    create(:comment_reaction, comment: comment, user: sam, kind: "eyes")
    comment.bump_reactions_version!
    CoPlan::Broadcaster.replace_to(plan, target: ActionView::RecordIdentifier.dom_id(comment, :reactions),
      partial: "coplan/comments/reactions", locals: { comment: comment.reload })
    expect(popover).to have_reaction("eyes", count: 1, pressed: false)

    page.execute_script(<<~JS, ActionView::RecordIdentifier.dom_id(thread_record), stale_thread)
      window.Turbo.renderStreamMessage(`<turbo-stream action="replace" target="${arguments[0]}"><template>${arguments[1]}</template></turbo-stream>`)
    JS

    reactions = "#comment_thread_#{thread_record.id}_popover " \
      "#reactions_comment_#{comment.id}[data-version='#{comment.reactions_version}']"
    expect(page).to have_css("#{reactions} .comment-reaction[data-kind='eyes'] .comment-reaction__count", exact_text: "1", visible: :all)
  end

  it "keeps working reaction controls in a cloned table discussion" do
    token_data = CoPlan::Plans::SourceTargets.new(plan.current_content).ranges.find { |kind, *| kind == "table_cell" }
    _, start, finish = token_data
    token = CoPlan::Plans::SourceTargets.verifier.generate(
      { "digest" => Digest::SHA256.hexdigest(plan.current_content), "kind" => "table_cell",
        "start" => start, "end" => finish, "label" => "Status" }, purpose: "comment")
    table_thread = plan.comment_threads.create!(plan_version: plan.current_plan_version, source_token: token,
      created_by_user: sam, status: "open")
    table_thread.comments.create!(author_type: "human", author_id: sam.id, body_markdown: "Queued for how long?")

    visit plan_page_path(plan)
    find(".data-grid .source-thread-badge").click
    panel = find(".source-comments", visible: true)
    expect(panel).to have_text("Queued for how long?")
    expect(panel).to have_css(".comment-reactions", count: 1)

    panel.find(".comment-reactions__add").click
    expect(page).to have_css(".comment-reactions__picker:popover-open")
    page.driver.browser.action.send_keys(:escape).perform
    expect(page).to have_no_css(".comment-reactions__picker:popover-open")
    expect(page).to have_css(".source-comments:popover-open")

    panel.find(".comment-reactions__add").click
    find(".comment-reactions__picker:popover-open .comment-reactions__option", text: "👍").click

    expect(panel).to have_reaction("thumbs_up", count: 1, pressed: true)
    expect(panel).to have_css(".comment-reactions", count: 1)
    wait_for { table_thread.comments.first.reactions.where(user: viewer, kind: "thumbs_up").exists? }

    panel.find(".comment-reaction[data-kind='thumbs_up']").send_keys(:enter)
    expect(panel).to have_no_css(".comment-reaction[data-kind='thumbs_up']")
    wait_for { !table_thread.comments.first.reactions.where(user: viewer).exists? }
    expect(page).to have_css(".source-comments .comment-reactions__add:focus")

    create(:comment_reaction, comment: table_thread.comments.first, user: sam, kind: "tada")
    table_thread.comments.first.bump_reactions_version!
    CoPlan::Broadcaster.replace_to(plan, target: ActionView::RecordIdentifier.dom_id(table_thread.comments.first, :reactions),
      partial: "coplan/comments/reactions", locals: { comment: table_thread.comments.first.reload })
    expect(panel).to have_reaction("tada", count: 1, pressed: false)
    panel.find(".comment-reaction[data-kind='tada']").send_keys(:enter)
    expect(panel).to have_reaction("tada", count: 2, pressed: true)
    wait_for { table_thread.comments.first.reactions.where(user: viewer, kind: "tada").exists? }
    expect(page).to have_css(".source-comments .comment-reaction[data-kind='tada']:focus")
  end
end
