import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { warning: String }

  confirmNavigation(event) {
    if (event.defaultPrevented || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return
    if (!this.hasWarningValue || !this.hasUnsavedChanges()) return
    if (window.confirm(this.warningValue)) return

    event.preventDefault()
    event.stopImmediatePropagation()
  }

  hasUnsavedChanges() {
    return Array.from(document.forms).some((form) =>
      Array.from(form.elements).some((control) => this.controlChanged(control))
    )
  }

  controlChanged(control) {
    if (!control.matches("input, textarea, select") || control.matches(":disabled") || control.readOnly) return false
    if (["hidden", "submit", "button", "reset", "image"].includes(control.type)) return false
    if (["checkbox", "radio"].includes(control.type)) return control.checked !== control.defaultChecked

    // Reset a detached copy so browser defaults (including a select's first
    // option and normalized dates) do not make an untouched form look edited.
    const defaults = control.cloneNode(true)
    const form = document.createElement("form")
    form.append(defaults)
    form.reset()

    if (control.tagName === "SELECT") {
      return Array.from(control.options).some((option, index) => option.selected !== defaults.options[index].selected)
    }

    return control.value !== defaults.value
  }

  close(event) {
    if (!this.element.open) return
    this.element.open = false
    if (event?.key === "Escape") this.element.querySelector("summary").focus()
  }

  closeOutside(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  closeOnFocusOut(event) {
    if (event.relatedTarget && !this.element.contains(event.relatedTarget)) this.close()
  }
}
