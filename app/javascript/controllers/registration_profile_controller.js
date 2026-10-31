import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["url", "token", "fetch", "manual", "status", "initial", "details", "identityFields", "summary", "summaryName", "summaryEmail", "firstName", "lastName", "email"]
  static values = { url: String, fetchLabel: String, loading: String, loaded: String, unavailable: String, stale: String, review: String, ready: Boolean, errors: Boolean, imported: Object, importedName: String }

  connect() {
    this.revision = 0
    this.lastImported = this.importedValue
    this.importedName = this.importedNameValue || (this.tokenTarget.value ? this.fullName() : "")
    this.previewToken = this.tokenTarget.value
    this.fetchTarget.type = "button"
    this.fetchTarget.disabled = false
    this.fetchTarget.textContent = this.fetchLabelValue
    this.fetchTarget.removeAttribute("aria-busy")
    this.manualTarget.hidden = false
    this.showDetails(this.readyValue)
    this.updateSummary()
    if (this.readyValue) {
      this.showIdentity(!this.tokenTarget.value || this.errorsValue || !this.identityValid())
      this.element.dataset.unsavedChanges = "true"
    }
  }

  disconnect() { this.request?.abort() }

  showDetails(ready) {
    this.ready = ready
    this.readyValue = ready
    this.detailsTargets.forEach((element) => {
      element.hidden = !ready
      if (element.tagName === "FIELDSET") element.disabled = !ready
      else element.querySelectorAll("input[type='submit'], button").forEach((button) => { button.disabled = !ready })
    })
    this.initialTargets.forEach((element) => { element.hidden = ready })
  }

  showIdentity(editable) {
    this.identityFieldsTarget.hidden = !editable
    this.summaryTarget.hidden = editable
  }

  manual(event) {
    event?.preventDefault()
    this.revision += 1
    this.request?.abort()
    this.previewToken = ""
    this.tokenTarget.value = ""
    this.showDetails(true)
    this.showIdentity(true)
    this.showStatus("")
    this.firstNameTarget.focus()
  }

  edit(event) {
    event.preventDefault()
    this.showIdentity(true)
    this.firstNameTarget.focus()
  }

  urlChanged() {
    if (this.applying) return
    const hadPreview = Boolean(this.tokenTarget.value || this.request)
    this.revision += 1
    this.request?.abort()
    this.previewToken = ""
    this.tokenTarget.value = ""
    if (this.ready) this.showIdentity(true)
    this.showStatus(hadPreview ? this.staleValue : "")
  }

  identityChanged() {
    if (this.applying) return
    this.revision += 1
    this.tokenTarget.value = this.normalizedName(this.fullName()) === this.normalizedName(this.importedName) ? this.previewToken : ""
    this.updateSummary()
  }

  async lookup(event) {
    event.preventDefault()
    if (this.request) return
    const profileUrl = this.urlTarget.value.trim()
    if (!this.urlTarget.checkValidity()) {
      this.urlTarget.reportValidity()
      return
    }
    const before = this.identityValues()
    const revision = this.revision
    const request = new AbortController()
    const timeout = setTimeout(() => request.abort(), 20000)
    const buttonLabel = this.fetchTarget.textContent
    this.request = request
    this.fetchTarget.disabled = true
    this.fetchTarget.textContent = this.loadingValue
    this.fetchTarget.setAttribute("aria-busy", "true")
    this.showStatus(this.loadingValue)
    try {
      const endpoint = new URL(this.urlValue, window.location.href)
      if (endpoint.origin !== window.location.origin) throw new Error("Unexpected profile origin")
      const response = await fetch(endpoint, {
        method: "POST", credentials: "same-origin", redirect: "error", signal: request.signal,
        headers: { "Accept": "application/json", "Content-Type": "application/json", "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content || "" },
        body: JSON.stringify({ registration: { directory_profile_url: profileUrl } })
      })
      const result = await response.json()
      if (!this.element.isConnected) return
      if (revision !== this.revision || profileUrl !== this.urlTarget.value.trim() || JSON.stringify(before) !== JSON.stringify(this.identityValues())) {
        this.showStatus(this.staleValue, true)
        return
      }
      const validResult = ["name", "first_name", "last_name", "email_address", "profile_url", "token"].every((key) => typeof result[key] === "string")
      if (!response.ok || result.status !== "ok" || !validResult || !result.token) {
        this.showStatus(typeof result.message === "string" ? result.message : this.unavailableValue, true)
        return
      }
      this.applying = true
      try {
        for (const [attribute, field] of Object.entries(this.identityFields())) {
          const value = result[attribute]
          if (typeof value === "string" && (!field.value.trim() || field.value === this.lastImported[attribute])) {
            field.value = value
            field.dispatchEvent(new Event("input", { bubbles: true }))
          }
        }
        if (typeof result.profile_url === "string") this.urlTarget.value = result.profile_url
        this.lastImported = { first_name: result.first_name, last_name: result.last_name, email_address: result.email_address }
        this.importedName = result.name
        this.importedValue = this.lastImported
        this.importedNameValue = this.importedName
        const matches = this.normalizedName(this.fullName()) === this.normalizedName(result.name)
        this.previewToken = result.token
        this.tokenTarget.value = matches ? result.token : ""
        this.showDetails(true)
        this.updateSummary()
        this.showIdentity(!matches || !this.identityValid())
        this.element.dataset.unsavedChanges = "true"
        this.showStatus(matches ? this.loadedValue : this.reviewValue)
      } finally {
        this.applying = false
      }
    } catch (error) {
      if (this.element.isConnected && revision === this.revision) this.showStatus(this.unavailableValue, true)
    } finally {
      clearTimeout(timeout)
      if (this.request === request) this.request = null
      this.fetchTarget.disabled = false
      this.fetchTarget.textContent = buttonLabel
      this.fetchTarget.removeAttribute("aria-busy")
    }
  }

  identityFields() { return { first_name: this.firstNameTarget, last_name: this.lastNameTarget, email_address: this.emailTarget } }
  identityValues() { return Object.fromEntries(Object.entries(this.identityFields()).map(([key, field]) => [key, field.value])) }
  fullName() { return `${this.firstNameTarget.value.trim()} ${this.lastNameTarget.value.trim()}`.trim() }
  normalizedName(value) { return value.toString().normalize("NFKD").toLowerCase().replace(/[^\p{L}\p{N}]/gu, "") }
  identityValid() { return Object.values(this.identityFields()).every((field) => field.checkValidity()) }
  updateSummary() {
    this.summaryNameTarget.textContent = this.fullName()
    this.summaryEmailTarget.textContent = this.emailTarget.value
  }
  showStatus(message, error = false) {
    this.statusTarget.textContent = message
    this.statusTarget.classList.toggle("registration-profile__status--error", error)
    this.statusTarget.setAttribute("role", error ? "alert" : "status")
  }
}
