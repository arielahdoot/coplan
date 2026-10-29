require "rails_helper"

RSpec.describe CoPlan::CommentReaction, type: :model do
  it "is valid with valid attributes" do
    expect(create(:comment_reaction)).to be_valid
  end

  it "only accepts kinds from the fixed set" do
    reaction = build(:comment_reaction, kind: "👍")
    expect(reaction).not_to be_valid
    expect(reaction.errors[:kind]).to include("is not included in the list")
  end

  it "allows one reaction of each kind per person per comment" do
    existing = create(:comment_reaction)
    duplicate = build(:comment_reaction, comment: existing.comment, user: existing.user, kind: existing.kind)
    expect(duplicate).not_to be_valid

    other_kind = build(:comment_reaction, comment: existing.comment, user: existing.user, kind: "heart")
    expect(other_kind).to be_valid
  end

  it "enforces uniqueness in the database too" do
    existing = create(:comment_reaction)
    duplicate = build(:comment_reaction, comment: existing.comment, user: existing.user, kind: existing.kind)
    expect { duplicate.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "maps every kind to an emoji and a spoken label" do
    described_class::KINDS.each_key do |kind|
      expect(described_class.emoji_for(kind)).to be_present
      expect(described_class.label_for(kind)).to be_present
    end
    expect(described_class.emoji_for("thumbs_up")).to eq("👍")
  end

  describe ".summarize" do
    it "groups by kind in the fixed order with reactors in the order they reacted" do
      comment = create(:comment)
      alex = create(:coplan_user, name: "Alex")
      sam = create(:coplan_user, name: "Sam")
      create(:comment_reaction, comment: comment, user: sam, kind: "rocket", created_at: 2.minutes.ago)
      create(:comment_reaction, comment: comment, user: alex, kind: "thumbs_up", created_at: 1.minute.ago)
      create(:comment_reaction, comment: comment, user: sam, kind: "thumbs_up", created_at: 3.minutes.ago)

      summary = described_class.summarize(comment.reactions.includes(:user))

      expect(summary.map { |entry| entry[:kind] }).to eq(%w[thumbs_up rocket])
      expect(summary.first).to include(emoji: "👍", count: 2)
      expect(summary.first[:reactions].map(&:user)).to eq([ sam, alex ])
    end
  end

  it "is removed with its comment" do
    reaction = create(:comment_reaction)
    reaction.comment.destroy!
    expect(described_class.exists?(reaction.id)).to be(false)
  end

  it "locks its comment before being removed with it, as reacting does" do
    reaction = create(:comment_reaction)
    statements = []
    collect = ->(*, payload) { statements << payload[:sql] }
    ActiveSupport::Notifications.subscribed(collect, "sql.active_record") { reaction.comment.destroy! }

    lock = statements.index { |sql| sql.match?(/coplan_comments\b.*FOR UPDATE/i) }
    delete = statements.index { |sql| sql.match?(/DELETE FROM [`"]?coplan_comment_reactions\b/i) }
    expect(lock).to be_present
    expect(lock).to be < delete
  end

  it "is removed with its user" do
    reaction = create(:comment_reaction)
    reaction.user.destroy!
    expect(described_class.exists?(reaction.id)).to be(false)
  end
end

RSpec.describe CoPlan::Comment, "#set_reaction!", type: :model do
  let(:comment) { create(:comment) }
  let(:user) { create(:coplan_user) }

  it "adds and removes a reaction, bumping the version each time" do
    expect { comment.set_reaction!(user: user, kind: "heart", reacted: true) }
      .to change { comment.reload.reactions_version }.by(1)
    expect(comment.reactions.where(user: user, kind: "heart")).to exist

    expect { comment.set_reaction!(user: user, kind: "heart", reacted: false) }
      .to change { comment.reload.reactions_version }.by(1)
    expect(comment.reactions).to be_empty
  end

  it "refuses a comment deleted since it was loaded, keeping the version" do
    stale = CoPlan::Comment.find(comment.id)
    comment.soft_delete!

    expect { stale.set_reaction!(user: user, kind: "heart", reacted: true) }
      .to raise_error(CoPlan::Comment::DeletedError)
    expect(comment.reload.reactions_version).to eq(0)
    expect(comment.reactions).to be_empty
  end

  it "refuses a comment destroyed since it was loaded" do
    stale = CoPlan::Comment.find(comment.id)
    comment.destroy!

    expect { stale.set_reaction!(user: user, kind: "heart", reacted: true) }
      .to raise_error(CoPlan::Comment::DeletedError)
    expect(CoPlan::CommentReaction.where(comment_id: comment.id)).to be_empty
  end

  it "keeps the version when the change fails" do
    allow(comment.reactions).to receive(:find_or_create_by!).and_raise(ActiveRecord::StatementInvalid)

    expect { comment.set_reaction!(user: user, kind: "heart", reacted: true) }.to raise_error(ActiveRecord::StatementInvalid)
    expect(comment.reload.reactions_version).to eq(0)
  end
end

RSpec.describe "Simultaneous comment reactions", type: :model do
  # Real concurrency needs real connections, which can't see each other's
  # uncommitted rows.
  self.use_transactional_tests = false

  after do
    truncate_tables("coplan_comment_reactions", "coplan_notifications", "coplan_comments", "coplan_comment_threads",
      *TruncationHelpers::PLAN_TABLES)
  end

  def in_parallel(count, &block)
    ready = Queue.new
    start = Queue.new
    threads = count.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ready << true
          start.pop
          block.call(index)
        end
      end
    end
    Timeout.timeout(20) { count.times { ready.pop } }
    count.times { start << true }
    threads.each { |thread| expect(thread.join(20)).to be_present }
    threads.map(&:value)
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
  end

  it "saves reactions from several people at once" do
    comment = create(:comment)
    users = Array.new(4) { create(:coplan_user) }

    in_parallel(users.size) { |index| CoPlan::Comment.find(comment.id).set_reaction!(user: users[index], kind: "tada", reacted: true) }

    expect(comment.reactions.count).to eq(4)
    expect(comment.reload.reactions_version).to eq(4)
  end

  it "saves one reaction when the same person adds it from several tabs at once" do
    comment = create(:comment)
    user = create(:coplan_user)

    in_parallel(3) { CoPlan::Comment.find(comment.id).set_reaction!(user: user, kind: "heart", reacted: true) }

    expect(comment.reactions.where(user: user, kind: "heart").count).to eq(1)
  end
end
