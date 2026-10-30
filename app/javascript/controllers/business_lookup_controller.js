import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["name", "number", "address", "postalCode", "city", "button", "status", "token", "source"]
  static values = { url: String, loading: String, unavailable: String, invalid: String, stale: String, loaded: String }

  connect() {
    this.revision = 0
  }

  disconnect() {
    this.request?.abort()
  }

  edited() {
    if (this.applying) return

    this.revision += 1
    // Keep the signed provenance so the server can retain attribution for
    // imported fields that still match after a manual correction.
    this.sourceTarget.textContent = ""
    this.sourceTarget.hidden = true
    this.statusTarget.textContent = ""
  }

  async lookup(event) {
    event.preventDefault()
    if (this.request) return

    const number = this.numberTarget.value.toUpperCase().trim().replace(/^BE/, "").replace(/[.\s-]/g, "")
    if (!/^\d{10}$/.test(number) || Number(number.slice(8)) !== 97 - (Number(number.slice(0, 8)) % 97)) {
      this.showStatus(this.invalidValue, true)
      this.numberTarget.focus()
      return
    }

    const before = this.fieldValues()
    const revision = this.revision
    const request = new AbortController()
    const timeout = setTimeout(() => request.abort(), 20000)
    const button = this.buttonTarget
    const buttonLabel = button.textContent
    this.request = request
    button.disabled = true
    button.textContent = this.loadingValue
    this.element.setAttribute("aria-busy", "true")
    this.showStatus(this.loadingValue)

    try {
      const endpoint = new URL(this.urlValue, window.location.href)
      if (endpoint.origin !== window.location.origin) throw new Error("Unexpected lookup origin")

      const response = await fetch(endpoint, {
        method: "POST",
        credentials: "same-origin",
        redirect: "error",
        headers: {
          "Accept": "application/json",
          "Content-Type": "application/json",
          "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content || ""
        },
        body: JSON.stringify({ enterprise_number: number }),
        signal: request.signal
      })
      const result = await response.json()
      if (!this.element.isConnected) return
      if (revision !== this.revision || JSON.stringify(before) !== JSON.stringify(this.fieldValues())) {
        this.showStatus(this.staleValue, true)
        return
      }
      if (!response.ok || result.status !== "ok" || typeof result.token !== "string" || !result.token) {
        this.showStatus(result.message || this.unavailableValue, true)
        return
      }

      this.applying = true
      try {
        for (const [attribute, field] of Object.entries(this.fields())) {
          const value = result.attributes?.[attribute]
          if (typeof value !== "string" || !value.trim()) continue

          field.value = value
          field.dispatchEvent(new Event("input", { bubbles: true }))
        }
        this.tokenTarget.value = result.token
        this.sourceTarget.textContent = result.source_label || ""
        this.sourceTarget.hidden = !result.source_label
        this.element.closest("form").dataset.unsavedChanges = "true"
      } finally {
        this.applying = false
      }
      this.showStatus(this.loadedValue)
    } catch (error) {
      if (this.element.isConnected) this.showStatus(this.unavailableValue, true)
    } finally {
      clearTimeout(timeout)
      this.request = null
      button.disabled = false
      button.textContent = buttonLabel
      this.element.removeAttribute("aria-busy")
    }
  }

  fields() {
    const fields = { name: this.nameTarget, enterprise_number: this.numberTarget }
    if (this.hasAddressTarget) fields.address_line_1 = this.addressTarget
    if (this.hasPostalCodeTarget) fields.postal_code = this.postalCodeTarget
    if (this.hasCityTarget) fields.city = this.cityTarget
    return fields
  }

  fieldValues() {
    return Object.fromEntries(Object.entries(this.fields()).map(([attribute, field]) => [attribute, field.value]))
  }

  showStatus(message, error = false) {
    this.statusTarget.textContent = message
    this.statusTarget.classList.toggle("business-lookup__status--error", error)
  }
}
