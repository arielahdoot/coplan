export function reactionsVersion(element) {
  return Number(element?.dataset.version)
}

// Replacing a thread or comment brings along its own copy of the chips,
// which may be older than the ones on screen. Keep the newer copy, and
// the one on screen at the same version: a render reads the version
// before the reactions, so the incoming copy may show fewer.
export function keepNewerReactions(root) {
  root.querySelectorAll(".comment-reactions[id]").forEach(incoming => {
    const onScreen = document.getElementById(incoming.id)
    if (onScreen && reactionsVersion(incoming) <= reactionsVersion(onScreen)) incoming.replaceWith(onScreen.cloneNode(true))
  })
}

// Whether a batch of DOM mutations touched nothing but reaction chips.
// Chips change with every reaction anyone makes, so observers waiting for
// a thread's own update can ignore them.
export function onlyReactionsChanged(records) {
  const reactions = node => node.nodeType === Node.TEXT_NODE ? !node.textContent.trim() : node.matches?.(".comment-reactions")
  return records.every(record => record.target.closest?.(".comment-reactions") ||
    [ ...record.addedNodes, ...record.removedNodes ].every(reactions))
}
