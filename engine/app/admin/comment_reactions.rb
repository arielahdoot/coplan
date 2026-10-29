ActiveAdmin.register CoPlan::CommentReaction, as: "CommentReaction" do
  actions :index, :show, :destroy

  filter :comment_id
  filter :user
  filter :kind, as: :select, collection: CoPlan::CommentReaction::KINDS.keys
  filter :created_at

  index do
    selectable_column
    id_column
    column :comment
    column :user
    column(:kind) { |reaction| "#{CoPlan::CommentReaction.emoji_for(reaction.kind)} #{reaction.kind}" }
    column :created_at
    actions
  end

  show do
    attributes_table do
      row :id
      row :comment
      row :user
      row(:kind) { |reaction| "#{CoPlan::CommentReaction.emoji_for(reaction.kind)} #{reaction.kind}" }
      row :created_at
      row :updated_at
    end
  end
end
