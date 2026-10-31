import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["select", "custom", "input"]
  static values = { other: String }

  connect() {
    this.toggle()
    this.reset = () => { this.resetTimer = setTimeout(() => this.toggle(), 0) }
    this.selectTarget.form?.addEventListener("reset", this.reset)
  }

  disconnect() {
    this.selectTarget.form?.removeEventListener("reset", this.reset)
    clearTimeout(this.resetTimer)
  }

  toggle(event) {
    const active = this.selectTarget.value === this.otherValue
    this.customTarget.hidden = !active
    this.inputTarget.disabled = !active
    this.inputTarget.required = active
    if (event && active) this.inputTarget.focus()
  }
}
