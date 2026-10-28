import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  connect() {
    this.element.closest("form")?.querySelectorAll(".field_with_errors input, .field_with_errors select, .field_with_errors textarea").forEach((field) => {
      field.setAttribute("aria-invalid", "true")
    })
    this.element.focus()
  }
}
