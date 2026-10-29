ActiveAdmin.register CoPlan::CommentReaction, as: "CommentReaction" do
  includes :comment, :user

  # Read-only: removing a reaction here would leave open pages showing it.
  # People remove their own reactions from the comment.
  actions :index, :show
  config.batch_actions = false

  # Rows outlive the kinds offered, so show a retired kind by name alone.
  kind_label = proc { |reaction| [ CoPlan::CommentReaction::KINDS.dig(reaction.kind, :emoji), reaction.kind ].compact.join(" ") }

  filter :comment_id
  filter :user
  filter :kind, as: :select, collection: CoPlan::CommentReaction::KINDS.keys
  filter :created_at

  index do
    id_column
    column :comment
    column :user
    column(:kind, &kind_label)
    column :created_at
    actions
  end

  show do
    attributes_table do
      row :id
      row :comment
      row :user
      row(:kind, &kind_label)
      row :created_at
      row :updated_at
    end
  end
end
