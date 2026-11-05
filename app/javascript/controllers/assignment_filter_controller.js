import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.timeout = null
    // Turbo can cache the next typed value under the previous history URL.
    // Reconcile only on page restoration, never during result-frame updates.
    const query = new URLSearchParams(window.location.search)
    for (const field of this.element.elements) {
      if (!["q", "kind", "city", "practice_area"].includes(field.name)) continue

      const value = query.get(field.name) || ""
      if (field.type === "radio") {
        field.checked = field.value === value
      } else if (field.value !== value) {
        field.value = value
        // Refresh an already connected searchable select without submitting.
        if (field.tagName === "SELECT") field.dispatchEvent(new Event("change"))
      }
    }
  }

  cancelPending() { clearTimeout(this.timeout) }

  submit() {
    this.cancelPending()
    this.element.requestSubmit()
  }

  debounce() {
    clearTimeout(this.timeout)
    this.timeout = setTimeout(() => this.submit(), 350)
  }

  disconnect() { clearTimeout(this.timeout) }
}
