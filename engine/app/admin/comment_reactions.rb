ActiveAdmin.register CoPlan::CommentReaction, as: "CommentReaction" do
  # Read-only: removing a reaction here would leave open pages showing it.
  # People remove their own reactions from the comment.
  actions :index, :show
  config.batch_actions = false

  kind_label = proc { |reaction| "#{CoPlan::CommentReaction.emoji_for(reaction.kind)} #{reaction.kind}" }

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
