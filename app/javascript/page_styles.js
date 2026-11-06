function orderPageStyles() {
  const boundary = document.head.querySelector("meta[name='lawrelay-stylesheets-end']")
  if (!boundary) return

  const styles = Array.from(document.head.querySelectorAll("link[rel='stylesheet'][data-lawrelay-stylesheet]"))
  styles.sort((left, right) => {
    const a = left.dataset.lawrelayStylesheet
    const b = right.dataset.lawrelayStylesheet
    return a < b ? -1 : a > b ? 1 : 0
  })
  for (const style of styles) document.head.insertBefore(style, boundary)
}

// Turbo loads new dynamic CSS and removes unused CSS before rendering.
// Reconcile its appended links before rendering or caching the page body.
document.addEventListener("turbo:before-render", orderPageStyles)
document.addEventListener("turbo:before-cache", orderPageStyles)
