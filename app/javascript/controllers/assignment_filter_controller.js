import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() { this.timeout = null }

  submit() { this.element.requestSubmit() }

  debounce() {
    clearTimeout(this.timeout)
    this.timeout = setTimeout(() => this.element.requestSubmit(), 350)
  }

  disconnect() { clearTimeout(this.timeout) }
}
