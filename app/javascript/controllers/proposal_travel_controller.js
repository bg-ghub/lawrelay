import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["choice", "cost", "input"]

  connect() {
    this.toggle()
    this.form = this.element.closest("form")
    this.reset = () => { this.resetTimer = setTimeout(() => this.toggle(), 0) }
    this.form?.addEventListener("reset", this.reset)
  }

  disconnect() {
    this.form?.removeEventListener("reset", this.reset)
    clearTimeout(this.resetTimer)
  }

  toggle(event) {
    const additional = this.choiceTargets.some((choice) => choice.checked && choice.value === "false")
    this.costTarget.hidden = !additional
    this.inputTarget.disabled = !additional
    this.inputTarget.required = additional
    if (event && additional) this.inputTarget.focus()
  }
}
