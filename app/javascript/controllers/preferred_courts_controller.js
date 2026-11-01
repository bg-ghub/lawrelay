import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["rows", "row", "template", "add", "remove"]
  static values = { limit: Number }

  connect() {
    this.nextIndex = Math.max(-1, ...this.rowTargets.map(row => Number(row.querySelector("input").id.replace("preferred-court-", "")))) + 1
    this.addTarget.hidden = false
    this.refresh()
  }

  add() {
    if (this.rowTargets.length >= this.limitValue) return

    const row = this.templateTarget.content.cloneNode(true)
    row.querySelector("input").id = `preferred-court-${this.nextIndex++}`
    this.rowsTarget.append(row)
    this.refresh()
    this.rowTargets.at(-1).querySelector("input").focus()
  }

  remove(event) {
    const row = event.currentTarget.closest("[data-preferred-courts-target='row']")
    if (this.rowTargets.length === 1) {
      row.querySelector("input").value = ""
      row.querySelector("input").focus()
    } else {
      const index = this.rowTargets.indexOf(row)
      row.remove()
      this.rowTargets[Math.min(index, this.rowTargets.length - 1)].querySelector("input").focus()
    }
    this.refresh()
  }

  refresh() {
    this.removeTargets.forEach(button => { button.hidden = false })
    this.addTarget.disabled = this.rowTargets.length >= this.limitValue
  }
}
