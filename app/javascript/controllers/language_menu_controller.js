import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static values = { warning: String, preferenceUrl: String, failure: String }

  async confirmNavigation(event) {
    if (event.defaultPrevented || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return
    if (this.hasWarningValue && this.hasUnsavedChanges() && !window.confirm(this.warningValue)) {
      event.preventDefault()
      event.stopImmediatePropagation()
      return
    }
    if (!this.preferenceUrlValue) return

    event.preventDefault()
    event.stopImmediatePropagation()
    if (this.saving) return

    const link = event.currentTarget
    const destination = new URL(link.href)
    if (!destination.hash) destination.hash = window.location.hash
    const headers = { "Content-Type": "application/json", "Accept": "application/json" }
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content
    if (csrfToken) headers["X-CSRF-Token"] = csrfToken

    this.saving = true
    try {
      const response = await fetch(this.preferenceUrlValue, {
        method: "PATCH", credentials: "same-origin", headers,
        body: JSON.stringify({ preferred_locale: link.hreflang })
      })
      if (!response.ok || response.redirected) throw new Error("Language preference was not saved")

      if (window.Turbo) window.Turbo.visit(destination.href)
      else window.location.assign(destination.href)
    } catch {
      window.alert(this.failureValue)
    } finally {
      this.saving = false
    }
  }

  hasUnsavedChanges() {
    return Array.from(document.forms).some((form) =>
      form.dataset.unsavedChanges === "true" ||
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
