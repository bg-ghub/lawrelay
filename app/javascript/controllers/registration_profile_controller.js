import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["url", "token", "fetch", "status", "initial", "details", "summaryName", "summaryEmail", "webmailHint"]
  static values = { url: String, fetchLabel: String, loading: String, loaded: String, unavailable: String, stale: String, ready: Boolean, importedName: String, listedEmail: String }

  connect() {
    this.revision = 0
    this.importedName = this.importedNameValue
    this.listedEmail = this.listedEmailValue
    this.fetchTarget.type = "button"
    this.fetchTarget.disabled = false
    this.fetchTarget.textContent = this.fetchLabelValue
    this.fetchTarget.removeAttribute("aria-busy")
    this.showDetails(this.readyValue && Boolean(this.tokenTarget.value))
    this.updateSummary()
    if (this.readyValue) this.element.dataset.unsavedChanges = "true"
  }

  disconnect() { this.request?.abort() }

  showDetails(ready) {
    this.readyValue = ready
    this.detailsTargets.forEach((element) => {
      element.hidden = !ready
      if (element.tagName === "FIELDSET") element.disabled = !ready
      else element.querySelectorAll("input[type='submit'], button").forEach((button) => { button.disabled = !ready })
    })
    this.initialTargets.forEach((element) => { element.hidden = ready })
  }

  urlChanged() {
    const hadPreview = Boolean(this.tokenTarget.value || this.request)
    this.revision += 1
    this.request?.abort()
    this.tokenTarget.value = ""
    this.importedName = ""
    this.listedEmail = ""
    this.importedNameValue = ""
    this.listedEmailValue = ""
    this.showDetails(false)
    this.updateSummary()
    this.showStatus(hadPreview ? this.staleValue : "")
  }

  async lookup(event) {
    event.preventDefault()
    if (this.request) return
    const profileUrl = this.urlTarget.value.trim()
    if (!this.urlTarget.checkValidity()) {
      this.urlTarget.reportValidity()
      return
    }
    const revision = this.revision
    const request = new AbortController()
    const timeout = setTimeout(() => request.abort(), 20000)
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
      if (revision !== this.revision || profileUrl !== this.urlTarget.value.trim()) {
        this.showStatus(this.staleValue, true)
        return
      }
      const validResult = ["name", "email_address", "profile_url", "token"].every((key) => typeof result[key] === "string" && result[key].length > 0)
      if (!response.ok || result.status !== "ok" || !validResult) {
        this.showStatus(typeof result.message === "string" ? result.message : this.unavailableValue, true)
        return
      }
      this.urlTarget.value = result.profile_url
      this.importedName = result.name
      this.listedEmail = result.email_address
      this.importedNameValue = this.importedName
      this.listedEmailValue = this.listedEmail
      this.tokenTarget.value = result.token
      this.showDetails(true)
      this.updateSummary()
      this.element.dataset.unsavedChanges = "true"
      this.showStatus(this.loadedValue)
    } catch (error) {
      if (this.element.isConnected && revision === this.revision) this.showStatus(this.unavailableValue, true)
    } finally {
      clearTimeout(timeout)
      if (this.request === request) this.request = null
      this.fetchTarget.disabled = false
      this.fetchTarget.textContent = this.fetchLabelValue
      this.fetchTarget.removeAttribute("aria-busy")
    }
  }

  updateSummary() {
    this.summaryNameTarget.textContent = this.importedName
    this.summaryEmailTarget.value = this.listedEmail
    this.webmailHintTarget.hidden = !/^[^@\s]+@advocaat\.be$/i.test(this.listedEmail.trim())
  }

  showStatus(message, error = false) {
    this.statusTarget.textContent = message
    this.statusTarget.classList.toggle("registration-profile__status--error", error)
    this.statusTarget.setAttribute("role", error ? "alert" : "status")
  }
}
