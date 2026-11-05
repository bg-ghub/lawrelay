import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.mobile = window.matchMedia("(max-width: 760px)")
    this.update = () => {
      const query = new URLSearchParams(window.location.search)
      const filtered = ["q", "kind", "city", "practice_area"].some(key => query.get(key)?.trim())
      this.element.open = !this.mobile.matches || filtered
    }
    this.mobile.addEventListener("change", this.update)
    this.update()
  }

  disconnect() {
    this.mobile.removeEventListener("change", this.update)
  }
}
