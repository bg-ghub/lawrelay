import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["form", "widget"]

  connect() {
    this.submitted = false
    this.onStateChange = this.handleStateChange.bind(this)
    this.widgetTarget.addEventListener("statechange", this.onStateChange)
    // The local proof can finish before Stimulus registers a listener when
    // ALTCHA starts on load. Start only after the listener is present.
    window.customElements.whenDefined("altcha-widget").then(() => {
      if (this.element.isConnected && this.hasWidgetTarget) this.widgetTarget.verify()
    })
  }

  disconnect() {
    this.widgetTarget.removeEventListener("statechange", this.onStateChange)
  }

  handleStateChange(event) {
    const { state, payload } = event.detail || {}
    if (state !== "verified" || !payload || this.submitted) return

    this.submitted = true
    const field = document.createElement("input")
    field.type = "hidden"
    field.name = "altcha"
    field.value = payload
    this.formTarget.appendChild(field)
    // The widget is form-associated and its internal control can still be
    // validating at this point. Native submit sends the completed proof
    // immediately instead of letting that transient browser validation block it.
    this.formTarget.submit()
  }
}
