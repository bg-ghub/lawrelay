import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["menu", "button"]

  toggle() {
    const isOpen = this.menuTarget.classList.toggle("is-open")
    this.buttonTarget.setAttribute("aria-expanded", isOpen)
    document.body.classList.toggle("menu-is-open", isOpen)
  }

  close() {
    if (!this.hasMenuTarget || !this.menuTarget.classList.contains("is-open")) return
    this.menuTarget.classList.remove("is-open")
    this.buttonTarget.setAttribute("aria-expanded", "false")
    document.body.classList.remove("menu-is-open")
  }

  disconnect() { document.body.classList.remove("menu-is-open") }
}
