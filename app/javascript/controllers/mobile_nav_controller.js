import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu", "button"]

  toggle() {
    if (this.menuTarget.classList.contains("is-open")) {
      this.close()
    } else {
      this.menuTarget.classList.add("is-open")
      this.buttonTarget.setAttribute("aria-expanded", "true")
      document.body.classList.add("menu-is-open")
      // The navigation precedes the trigger in the document. Place keyboard
      // focus inside it so its newly-visible links are reachable immediately.
      this.menuTarget.querySelector("a, button")?.focus()
    }
  }

  close(event) {
    if (!this.hasMenuTarget || !this.menuTarget.classList.contains("is-open")) return
    this.menuTarget.classList.remove("is-open")
    this.buttonTarget.setAttribute("aria-expanded", "false")
    document.body.classList.remove("menu-is-open")
    if (event?.key === "Escape") this.buttonTarget.focus()
  }

  closeOutside(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  closeOnFocusOut(event) {
    if (event.relatedTarget && !this.element.contains(event.relatedTarget)) this.close()
  }

  reset() { this.close() }

  disconnect() { document.body.classList.remove("menu-is-open") }
}
