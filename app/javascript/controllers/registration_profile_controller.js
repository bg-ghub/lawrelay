import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["url", "token", "fetch", "status", "initial", "details", "summaryName", "summaryEmail", "webmailHint", "nameQuery", "search", "searchStatus", "results", "searchTruncated"]
  static values = { url: String, fetchLabel: String, loading: String, loaded: String, unavailable: String, stale: String, ready: Boolean, importedName: String, listedEmail: String, searchUrl: String, searchLabel: String, searchLoading: String, searchEmpty: String, searchChoose: String, searchUse: String, searchInvalid: String, searchUnavailable: String }

  connect() {
    this.revision = (this.revision || 0) + 1
    this.searchRevision = (this.searchRevision || 0) + 1
    this.request?.abort()
    this.searchRequest?.abort()
    this.request = null
    this.searchRequest = null
    this.importedName = this.importedNameValue
    this.listedEmail = this.listedEmailValue
    this.fetchTarget.type = "button"
    this.fetchTarget.disabled = false
    this.fetchTarget.textContent = this.fetchLabelValue
    this.fetchTarget.removeAttribute("aria-busy")
    this.searchTarget.type = "button"
    this.setSearching(false)
    this.showDetails(this.readyValue && Boolean(this.tokenTarget.value))
    this.updateSummary()
    if (this.readyValue) this.element.dataset.unsavedChanges = "true"
  }

  disconnect() {
    this.request?.abort()
    this.searchRequest?.abort()
  }

  nameChanged() {
    this.searchRevision += 1
    this.searchRequest?.abort()
    this.searchRequest = null
    this.setSearching(false)
    this.resultsTarget.replaceChildren()
    this.searchTruncatedTarget.hidden = true
    this.showSearchStatus("")
    this.urlTarget.value = ""
    this.urlChanged()
  }

  async search(event) {
    event.preventDefault()
    const query = this.nameQueryTarget.value.trim()
    if (query.length < 3 || query.length > 100) {
      this.showSearchStatus(this.searchInvalidValue, true)
      this.nameQueryTarget.focus()
      return
    }
    this.nameChanged()
    const revision = this.searchRevision
    const request = new AbortController()
    const timeout = setTimeout(() => request.abort(), 20000)
    this.searchRequest = request
    this.setSearching(true)
    this.showSearchStatus(this.searchLoadingValue)
    try {
      const endpoint = new URL(this.searchUrlValue, window.location.href)
      if (endpoint.origin !== window.location.origin) throw new Error("Unexpected search origin")
      const response = await fetch(endpoint, {
        method: "POST", credentials: "same-origin", redirect: "error", signal: request.signal,
        headers: { "Accept": "application/json", "Content-Type": "application/json", "X-CSRF-Token": document.querySelector("meta[name='csrf-token']")?.content || "" },
        body: JSON.stringify({ registration: { name_query: query } })
      })
      const result = await response.json()
      if (!this.element.isConnected || revision !== this.searchRevision || query !== this.nameQueryTarget.value.trim()) return
      if (!response.ok || result.status !== "ok" || !Array.isArray(result.candidates)) {
        this.showSearchStatus(typeof result.message === "string" ? result.message : this.searchUnavailableValue, true)
        return
      }
      const rendered = this.renderCandidates(result.candidates)
      if (result.candidates.length && !rendered) {
        this.showSearchStatus(this.searchUnavailableValue, true)
        return
      }
      this.searchTruncatedTarget.hidden = !result.truncated
      this.showSearchStatus(result.candidates.length ? this.searchChooseValue : this.searchEmptyValue)
    } catch (error) {
      if (this.element.isConnected && revision === this.searchRevision) this.showSearchStatus(this.searchUnavailableValue, true)
    } finally {
      clearTimeout(timeout)
      if (this.searchRequest === request) {
        this.searchRequest = null
        this.setSearching(false)
      }
    }
  }

  renderCandidates(candidates) {
    this.resultsTarget.replaceChildren()
    candidates.slice(0, 8).forEach((candidate) => {
      if (typeof candidate.name !== "string" || (candidate.location != null && typeof candidate.location !== "string") || typeof candidate.profile_url !== "string") return
      if (!/^https:\/\/www\.advocaat\.be\/nl\/zoek-een-advocaat\/advocaat\/[0-9a-f-]{36}$/i.test(candidate.profile_url)) return
      const item = document.createElement("li")
      const button = document.createElement("button")
      button.type = "button"
      button.className = "registration-search__candidate"
      button.dataset.action = "click->registration-profile#chooseProfile"
      button.dataset.profileUrl = candidate.profile_url
      const identity = document.createElement("span")
      const name = document.createElement("strong")
      name.textContent = candidate.name
      const action = document.createElement("span")
      action.className = "registration-search__choose"
      action.textContent = this.searchUseValue
      identity.append(name)
      if (typeof candidate.location === "string" && candidate.location.trim()) {
        const location = document.createElement("span")
        location.className = "registration-search__location"
        location.textContent = candidate.location
        identity.append(location)
      }
      button.append(identity, action)
      item.append(button)
      this.resultsTarget.append(item)
    })
    return this.resultsTarget.childElementCount
  }

  chooseProfile(event) {
    event.preventDefault()
    this.urlTarget.value = event.currentTarget.dataset.profileUrl
    this.urlChanged()
    this.lookup(event)
  }

  setSearching(searching) {
    this.searchTarget.disabled = searching
    this.searchTarget.textContent = searching ? this.searchLoadingValue : this.searchLabelValue
    if (searching) this.searchTarget.setAttribute("aria-busy", "true")
    else this.searchTarget.removeAttribute("aria-busy")
  }

  showSearchStatus(message, error = false) {
    this.searchStatusTarget.textContent = message
    this.searchStatusTarget.classList.toggle("registration-profile__status--error", error)
    this.searchStatusTarget.setAttribute("role", error ? "alert" : "status")
  }

  showDetails(ready) {
    this.readyValue = ready
    this.detailsTargets.forEach((element) => {
      element.hidden = !ready
      if (element.tagName === "FIELDSET") element.disabled = !ready
      else element.querySelectorAll("input[type='submit'], button").forEach((button) => { button.disabled = !ready })
    })
    this.initialTargets.forEach((element) => { element.hidden = ready })
  }

  urlChanged(event) {
    if (event?.type === "input") {
      this.searchRevision += 1
      this.searchRequest?.abort()
      this.searchRequest = null
      this.setSearching(false)
      this.resultsTarget.replaceChildren()
      this.searchTruncatedTarget.hidden = true
      this.showSearchStatus("")
    }
    const hadPreview = Boolean(this.tokenTarget.value || this.request)
    this.revision += 1
    this.request?.abort()
    this.request = null
    this.fetchTarget.disabled = false
    this.fetchTarget.textContent = this.fetchLabelValue
    this.fetchTarget.removeAttribute("aria-busy")
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
      if (this.request === request) {
        this.request = null
        this.fetchTarget.disabled = false
        this.fetchTarget.textContent = this.fetchLabelValue
        this.fetchTarget.removeAttribute("aria-busy")
      }
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
