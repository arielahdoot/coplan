export function reactionsVersion(element) {
  return Number(element?.dataset.version)
}

// Replacing a thread or comment brings along its own copy of the chips,
// which may be older than the ones on screen. Keep the newer copy.
export function keepNewerReactions(root) {
  root.querySelectorAll(".comment-reactions[id]").forEach(incoming => {
    const onScreen = document.getElementById(incoming.id)
    if (onScreen && reactionsVersion(incoming) < reactionsVersion(onScreen)) incoming.replaceWith(onScreen.cloneNode(true))
  })
}
