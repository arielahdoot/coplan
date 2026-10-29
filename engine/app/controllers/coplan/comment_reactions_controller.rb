module CoPlan
  class CommentReactionsController < ApplicationController
    before_action :set_comment

    # PATCH with `kind` and `reacted` (true or false). Sending the desired
    # state rather than "toggle" keeps repeated or retried requests from
    # flipping the reaction back.
    def update
      authorize!(@plan, :show?)

      kind = params[:kind].to_s
      reacted = { "true" => true, "false" => false }[params[:reacted].to_s]
      unless CommentReaction::KINDS.key?(kind) && !reacted.nil?
        render plain: "Unknown reaction.", status: :unprocessable_content
        return
      end
      if @comment.deleted?
        render plain: "You can't react to a deleted comment.", status: :unprocessable_content
        return
      end

      # Saving inside each format means a request for any other format is
      # refused before anything changes.
      respond_to do |format|
        format.turbo_stream do
          target = save_reaction(kind, reacted)
          html = render_to_string(partial: "coplan/comments/reactions", locals: { comment: @comment }, formats: [ :html ])
          render turbo_stream: turbo_stream.replace(target, html)
        end
        format.html do
          save_reaction(kind, reacted)
          redirect_to helpers.plan_browse_path(@plan)
        end
      end
    end

    private

    def save_reaction(kind, reacted)
      @comment.set_reaction!(user: current_user, kind: kind, reacted: reacted)
      @comment.reload
      CommentReaction.preload_for(@comment)
      target = ActionView::RecordIdentifier.dom_id(@comment, :reactions)
      Broadcaster.replace_to(@plan, target: target, partial: "coplan/comments/reactions", locals: { comment: @comment })
      target
    end

    def set_comment
      @plan = Plan.find(params[:plan_id])
      thread = @plan.comment_threads.find(params[:comment_thread_id])
      @comment = thread.comments.find(params[:comment_id])
    end
  end
end
