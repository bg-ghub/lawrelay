import { Controller } from "@hotwired/stimulus"

// The native select remains the only submitted control and the no-JS fallback.
export default class extends Controller {
  static targets = ["source"]
  static values = { placeholder: String, empty: String, choose: String, count: String }

  connect() {
    this.source = this.sourceTarget
    this.original = { hidden: this.source.hidden, tabindex: this.source.getAttribute("tabindex"), ariaHidden: this.source.getAttribute("aria-hidden") }
    this.labels = Array.from(this.source.labels || [])
    const id = this.source.id.replace(/[^\w:-]+/g, "_").replace(/_+$/, "")
    this.input = document.createElement("input")
    this.input.type = "text"
    this.input.id = `${id}-search`
    this.input.className = `${this.source.className} searchable-select__input`
    this.input.autocomplete = "off"
    this.input.spellcheck = false
    this.input.role = "combobox"
    this.input.setAttribute("aria-autocomplete", "list")
    this.input.setAttribute("aria-expanded", "false")
    this.list = document.createElement("ul")
    this.list.id = `${id}-options`
    this.list.role = "listbox"
    this.list.setAttribute("aria-label", this.labels.map((label) => label.textContent.trim()).join(" ") || this.source.getAttribute("aria-label") || this.placeholderValue)
    this.list.className = "searchable-select__list"
    this.list.hidden = true
    this.input.setAttribute("aria-controls", this.list.id)
    this.status = document.createElement("p")
    this.status.id = `${id}-results`
    this.status.className = "searchable-select__status"
    this.status.role = "status"
    this.status.setAttribute("aria-live", "polite")
    this.status.hidden = true
    this.labels.forEach((label) => { label.htmlFor = this.input.id })
    this.source.hidden = true
    this.source.tabIndex = -1
    this.source.setAttribute("aria-hidden", "true")
    this.source.after(this.input, this.list, this.status)
    this.listen(this.input, "focus", () => {
      if (!this.list.hidden) return
      this.input.select()
      this.open(this.editing ? this.input.value : "")
    })
    this.listen(this.input, "pointerup", () => { if (!this.editing) this.input.select() })
    this.listen(this.input, "click", () => { if (this.list.hidden) this.open(this.editing ? this.input.value : "") })
    this.listen(this.input, "input", () => this.changed())
    this.listen(this.input, "change", (event) => event.stopPropagation())
    this.listen(this.input, "keydown", (event) => this.keydown(event))
    this.listen(this.input, "blur", () => this.blurred())
    this.listen(this.source, "change", () => { this.syncSelection(); this.close() })
    this.listen(this.source, "invalid", (event) => { event.preventDefault(); this.input.focus(); this.input.reportValidity() })
    this.listen(this.list, "pointerdown", (event) => {
      this.pointerInside = true
      // Options retain input focus; the scrollbar keeps its native drag action.
      if (event.target.closest('[role="option"]')) event.preventDefault()
    })
    this.listen(this.list, "click", (event) => {
      const option = event.target.closest('[role="option"]')
      if (option) this.commit(this.matches[Number(option.dataset.index)])
    })
    this.listen(window, "pointerup", () => this.releasePointer())
    this.listen(window, "pointercancel", () => this.releasePointer())
    this.listen(document, "pointerdown", (event) => { if (!this.element.contains(event.target)) this.close() })
    this.listen(document, "turbo:before-cache", () => this.destroy())
    if (this.source.form) this.listen(this.source.form, "reset", () => { this.resetTimer = setTimeout(() => this.syncSelection(true), 0) })
    this.observer = new MutationObserver((records) => {
      if (records.some((record) => record.type === "childList" || record.target !== this.source)) this.syncSelection()
      this.syncState()
    })
    this.observer.observe(this.source, { attributes: true, attributeFilter: ["disabled", "required", "selected", "label", "aria-invalid", "aria-describedby", "aria-label"], childList: true, subtree: true })
    this.syncSelection(true)
    this.syncState()
  }

  listen(target, event, handler) {
    this.listeners ||= []
    target.addEventListener(event, handler)
    this.listeners.push(() => target.removeEventListener(event, handler))
  }

  disconnect() { this.destroy() }

  destroy() {
    if (!this.input) return
    this.observer?.disconnect()
    clearTimeout(this.resetTimer)
    this.listeners?.forEach((remove) => remove())
    this.listeners = []
    this.labels.forEach((label) => { if (label.htmlFor === this.input.id) label.htmlFor = this.source.id })
    this.source.hidden = this.original.hidden
    this.restoreAttribute("tabindex", this.original.tabindex)
    this.restoreAttribute("aria-hidden", this.original.ariaHidden)
    this.input.remove()
    this.list.remove()
    this.status.remove()
    this.input = null
  }

  restoreAttribute(name, value) {
    value === null ? this.source.removeAttribute(name) : this.source.setAttribute(name, value)
  }

  normalize(value) {
    return value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase().trim()
  }

  options() {
    return Array.from(this.source.options).map((option, index) => ({
      index, value: option.value, label: option.label,
      disabled: option.disabled || option.parentElement.disabled,
      search: this.normalize(`${option.label} ${option.value} ${option.parentElement.label || ""}`)
    })).filter((option) => !option.disabled)
  }

  syncSelection(defaults = false) {
    this.selection = this.options().find((option) => option.index === this.source.selectedIndex)
    this.editing = false
    this.input.value = this.selection && (this.selection.value || !this.source.required) ? this.selection.label : ""
    if (defaults) this.input.defaultValue = this.input.value
    this.input.placeholder = this.source.options[0]?.value === "" ? this.source.options[0].label : this.placeholderValue
    this.updateValidity()
  }

  syncState() {
    this.input.disabled = this.source.disabled
    this.input.required = this.source.required && !this.source.disabled
    for (const attribute of ["aria-invalid", "aria-label"]) {
      const value = this.source.getAttribute(attribute)
      value === null ? this.input.removeAttribute(attribute) : this.input.setAttribute(attribute, value)
    }
    this.input.setAttribute("aria-describedby", [this.source.getAttribute("aria-describedby"), this.status.id].filter(Boolean).join(" "))
    if (this.source.disabled) this.close()
    this.updateValidity()
  }

  updateValidity() {
    const blankAllowed = !this.source.required && Array.from(this.source.options).some((option) => option.value === "")
    const invalid = this.editing && this.input.value.trim() !== "" ||
      this.source.selectedIndex < 0 && !blankAllowed || this.source.required && this.source.value === ""
    this.input.setCustomValidity(this.source.disabled || !invalid ? "" : this.chooseValue)
  }

  changed() {
    this.editing = true
    this.source.selectedIndex = -1
    this.updateValidity()
    this.open(this.input.value)
  }

  open(query = this.input.value) {
    if (this.input.disabled) return
    const words = this.normalize(query).split(/\s+/).filter(Boolean)
    this.matches = this.options().filter((option) => words.every((word) => option.search.includes(word)))
    this.active = -1
    this.list.replaceChildren(...this.matches.map((option, index) => {
      const item = document.createElement("li")
      item.id = `${this.list.id}-${index}`
      item.role = "option"
      item.setAttribute("aria-selected", "false")
      item.dataset.index = index
      item.textContent = option.label
      return item
    }))
    this.list.hidden = this.matches.length === 0
    this.status.textContent = this.matches.length ? this.countValue.replace("%{count}", this.matches.length) : this.emptyValue
    this.status.classList.toggle("is-empty", this.matches.length === 0)
    this.status.hidden = false
    this.input.setAttribute("aria-expanded", String(this.matches.length > 0))
    this.input.removeAttribute("aria-activedescendant")
  }

  commit(option) {
    if (!option) return
    this.source.selectedIndex = option.index
    this.syncSelection()
    this.close()
    this.source.dispatchEvent(new Event("input", { bubbles: true }))
    this.source.dispatchEvent(new Event("change", { bubbles: true }))
  }

  blurred() {
    if (this.pointerInside || this.list.matches(":hover")) return
    if (this.editing) {
      const text = this.normalize(this.input.value)
      const options = this.options().filter((option) => this.normalize(option.label) === text || !text && option.value === "")
      if (options.length === 1 && (text || !this.source.required)) this.commit(options[0])
    }
    this.close()
  }

  releasePointer() {
    const restoreFocus = this.pointerInside && !this.list.hidden
    this.pointerInside = false
    if (restoreFocus) this.input.focus({ preventScroll: true })
  }

  keydown(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      event.stopPropagation()
      if (this.editing) {
        this.source.selectedIndex = this.selection?.index ?? -1
        this.syncSelection()
      }
      this.close()
    } else if (event.key === "Tab") {
      this.close()
    } else if (["ArrowDown", "ArrowUp"].includes(event.key) || ["Home", "End"].includes(event.key) && !this.list.hidden) {
      event.preventDefault()
      if (this.list.hidden) this.open(this.editing ? this.input.value : "")
      if (!this.matches.length) return
      if (event.key === "Home") this.active = 0
      else if (event.key === "End") this.active = this.matches.length - 1
      else if (this.active < 0) this.active = event.key === "ArrowDown" ? 0 : this.matches.length - 1
      else this.active = (this.active + (event.key === "ArrowDown" ? 1 : -1) + this.matches.length) % this.matches.length
      Array.from(this.list.children).forEach((item, index) => item.setAttribute("aria-selected", String(index === this.active)))
      const option = this.list.children[this.active]
      this.input.setAttribute("aria-activedescendant", option.id)
      option.scrollIntoView({ block: "nearest" })
    } else if (event.key === "Enter" && !this.list.hidden) {
      event.preventDefault()
      event.stopPropagation()
      if (this.active >= 0) this.commit(this.matches[this.active])
      else if (this.matches.length === 1) this.commit(this.matches[0])
      else this.close()
    }
  }

  close() {
    this.list.hidden = true
    this.status.hidden = true
    this.input.setAttribute("aria-expanded", "false")
    this.input.removeAttribute("aria-activedescendant")
    this.active = -1
  }
}
