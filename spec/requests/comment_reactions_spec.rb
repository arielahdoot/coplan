require "rails_helper"

RSpec.describe "Comment reactions", type: :request do
  let(:alice) { create(:coplan_user, name: "Alice Archer") }
  let(:bob) { create(:coplan_user, name: "Bob Baker") }
  let(:plan) { create(:plan, :considering, created_by_user: alice) }
  let(:thread_record) { create(:comment_thread, plan: plan, plan_version: plan.current_plan_version, created_by_user: alice) }
  let(:comment) { create(:comment, comment_thread: thread_record, author_id: alice.id) }
  let(:turbo) { { "Accept" => "text/vnd.turbo-stream.html" } }

  def react(kind: "thumbs_up", reacted: true, as_comment: comment)
    patch plan_comment_thread_comment_reactions_path(plan, thread_record, as_comment),
      params: { kind: kind, reacted: reacted }, headers: turbo
  end

  before { sign_in_as(bob) }

  it "adds the signed-in person's reaction and returns the chips inline" do
    expect { react }.to change(CoPlan::CommentReaction, :count).by(1)

    expect(response).to have_http_status(:ok)
    reaction = CoPlan::CommentReaction.last
    expect(reaction).to have_attributes(comment_id: comment.id, user_id: bob.id, kind: "thumbs_up")
    expect(response.body).to include(%(action="replace"))
    expect(response.body).to include(ActionView::RecordIdentifier.dom_id(comment, :reactions))
    expect(response.body).to include("Bob Baker reacted with thumbs up")
  end

  it "is idempotent when the reaction already exists" do
    create(:comment_reaction, comment: comment, user: bob, kind: "heart")

    expect { react(kind: "heart") }.not_to change(CoPlan::CommentReaction, :count)
    expect(response).to have_http_status(:ok)
  end

  it "treats a concurrent add of the same reaction as success" do
    create(:comment_reaction, comment: comment, user: bob, kind: "thumbs_up")
    # Another request inserts the row after this request's lookup misses it.
    allow_any_instance_of(ActiveRecord::Relation).to receive(:find_by).and_wrap_original do |original, *args, **kwargs|
      original.receiver.klass == CoPlan::CommentReaction ? nil : original.call(*args, **kwargs)
    end

    expect { react }.not_to change(CoPlan::CommentReaction, :count)
    expect(response).to have_http_status(:ok)
  end

  it "removes only the signed-in person's reaction" do
    create(:comment_reaction, comment: comment, user: bob, kind: "rocket")
    create(:comment_reaction, comment: comment, user: alice, kind: "rocket")

    expect { react(kind: "rocket", reacted: false) }.to change(CoPlan::CommentReaction, :count).by(-1)

    expect(response).to have_http_status(:ok)
    expect(comment.reactions.pluck(:user_id)).to eq([ alice.id ])
    expect(response.body).to include("Alice Archer reacted with rocket")
  end

  it "rejects a kind outside the fixed set" do
    expect { react(kind: "👍") }.not_to change(CoPlan::CommentReaction, :count)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "requires the desired state" do
    expect { react(reacted: "") }.not_to change(CoPlan::CommentReaction, :count)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "rejects reactions on a deleted comment" do
    comment.soft_delete!

    expect { react }.not_to change(CoPlan::CommentReaction, :count)
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "rejects a signed-out request" do
    comment
    reset!

    expect { react }.not_to change(CoPlan::CommentReaction, :count)
    expect(response).not_to have_http_status(:ok)
  end

  it "returns not found for a comment nested under a different thread" do
    other_thread = create(:comment_thread, plan: plan)

    expect {
      patch plan_comment_thread_comment_reactions_path(plan, other_thread, comment),
        params: { kind: "thumbs_up", reacted: true }, headers: turbo
    }.not_to change(CoPlan::CommentReaction, :count)
    expect(response).to have_http_status(:not_found)
  end

  it "broadcasts a requestless render of the chips" do
    comment
    expect(CoPlan::Broadcaster).to receive(:replace_to) do |streamable, **kwargs|
      expect(streamable).to eq(plan)
      expect(kwargs[:target]).to eq(ActionView::RecordIdentifier.dom_id(comment, :reactions))
      expect(kwargs[:partial]).to eq("coplan/comments/reactions")
      expect(kwargs[:html]).to be_nil
    end

    react
  end

  it "does not notify anyone" do
    comment
    expect { react }.not_to change(CoPlan::Notification, :count)
    expect { react(kind: "eyes") }.not_to have_enqueued_job
  end
end
