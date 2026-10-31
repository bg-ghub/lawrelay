import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "city", "list", "status"]
  static values = { options: Array, count: String, empty: String }

  connect() {
    this.options = this.optionsValue.map((option) => ({ ...option, normalized: this.normalize(option.search) }))
    this.selected = this.options.find((option) => option.label === this.inputTarget.value && option.city === this.cityTarget.value)
    this.active = -1
    this.close()
  }

  disconnect() {
    clearTimeout(this.blurTimeout)
  }

  normalize(value) {
    return value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase()
  }

  changed() {
    if (this.selected && this.inputTarget.value !== this.selected.label) {
      if (this.cityTarget.value === this.selected.city) this.cityTarget.value = ""
      this.selected = null
    }
    this.open()
  }

  open() {
    if (this.inputTarget.disabled) return
    const words = this.normalize(this.inputTarget.value).trim().split(/\s+/).filter(Boolean)
    this.matches = this.options.filter((option) => words.every((word) => option.normalized.includes(word)))
    this.active = -1
    this.listTarget.replaceChildren(...this.matches.map((option, index) => {
      const element = document.createElement("li")
      element.id = `${this.listTarget.id}-${index}`
      element.role = "option"
      element.setAttribute("aria-selected", "false")
      element.dataset.index = index
      element.dataset.action = "pointerdown->court-picker#keepFocus click->court-picker#choose"
      element.textContent = option.label
      return element
    }))
    this.listTarget.hidden = this.matches.length === 0
    this.statusTarget.textContent = this.matches.length ? this.countValue.replace("%{count}", this.matches.length) : this.emptyValue
    this.statusTarget.hidden = false
    this.inputTarget.setAttribute("aria-expanded", this.matches.length ? "true" : "false")
    this.inputTarget.removeAttribute("aria-activedescendant")
  }

  keepFocus(event) {
    event.preventDefault()
  }

  choose(event) {
    this.select(Number(event.currentTarget.dataset.index))
  }

  select(index) {
    const option = this.matches[index]
    if (!option) return
    this.inputTarget.value = option.label
    this.cityTarget.value = option.city
    this.selected = option
    this.close()
    this.inputTarget.dispatchEvent(new Event("change", { bubbles: true }))
    this.cityTarget.dispatchEvent(new Event("input", { bubbles: true }))
    this.cityTarget.dispatchEvent(new Event("change", { bubbles: true }))
  }

  keydown(event) {
    if (event.key === "Escape") {
      event.preventDefault()
      event.stopPropagation()
      this.close()
    } else if (event.key === "Tab") {
      this.close()
    } else if (["ArrowDown", "ArrowUp"].includes(event.key) || ["Home", "End"].includes(event.key) && !this.listTarget.hidden) {
      if (this.listTarget.hidden) this.open()
      if (!this.matches.length) return
      event.preventDefault()
      if (event.key === "Home") this.active = 0
      else if (event.key === "End") this.active = this.matches.length - 1
      else if (this.active < 0) this.active = event.key === "ArrowDown" ? 0 : this.matches.length - 1
      else this.active = (this.active + (event.key === "ArrowDown" ? 1 : -1) + this.matches.length) % this.matches.length
      this.highlight()
    } else if (event.key === "Enter" && !this.listTarget.hidden) {
      event.preventDefault()
      if (this.active >= 0) this.select(this.active)
      else this.close()
    }
  }

  highlight() {
    Array.from(this.listTarget.children).forEach((element, index) => {
      element.setAttribute("aria-selected", index === this.active ? "true" : "false")
    })
    const option = this.listTarget.children[this.active]
    this.inputTarget.setAttribute("aria-activedescendant", option.id)
    option.scrollIntoView({ block: "nearest" })
  }

  blur(event) {
    if (this.element.contains(event.relatedTarget)) return
    this.close()
  }

  outside(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  kindChanged(event) {
    if (event.target.matches('input[name$="[kind]"]')) this.close()
  }

  close() {
    this.listTarget.hidden = true
    this.statusTarget.hidden = true
    this.inputTarget.setAttribute("aria-expanded", "false")
    this.inputTarget.removeAttribute("aria-activedescendant")
    this.active = -1
  }
}
