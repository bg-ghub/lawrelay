import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "selection", "other", "otherField", "city", "cityField", "list", "status"]
  static values = { options: Array, count: String, empty: String, other: String, choose: String }

  connect() {
    this.options = this.optionsValue.map((option) => ({ ...option, normalized: this.normalize(option.search) }))
    const originalCourt = this.inputTarget.value
    this.recognizeSelection()
    if (this.selectionTarget.value === "__other__" || (!this.selected && originalCourt)) {
      this.selected = null
      this.otherSelected = true
      if (!this.otherTarget.value && originalCourt !== "__other__") this.otherTarget.value = originalCourt
      this.inputTarget.value = this.otherValue
      this.selectionTarget.value = "__other__"
      if (!this.selected && originalCourt && this.selectionTarget.disabled) {
        this.inputTarget.defaultValue = this.otherValue
        this.otherTarget.defaultValue = this.otherTarget.value
      }
    } else if (this.selected) {
      this.selectionTarget.value = originalCourt
    }
    this.updateFields()
    this.active = -1
    this.close()
  }

  normalize(value) {
    return value.normalize("NFD").replace(/[\u0300-\u036f]/g, "").toLowerCase()
  }

  changed() {
    this.otherSelected = false
    if (this.selected && this.inputTarget.value !== this.selectedLabel) {
      if (this.cityTarget.value === this.selectedCity) this.cityTarget.value = ""
      this.selected = null
    }
    this.recognizeSelection()
    this.selectionTarget.value = this.selected ? this.inputTarget.value : ""
    this.updateFields()
    this.open()
  }

  recognizeSelection() {
    this.selected = this.options.find((option) =>
      (option.labels || [option.label]).includes(this.inputTarget.value) &&
      (!this.cityTarget.value || (option.cities || [option.city]).includes(this.cityTarget.value))
    )
    if (!this.selected) return

    if (!this.cityTarget.value) this.cityTarget.value = this.selected.city
    this.selectedLabel = this.inputTarget.value
    this.selectedCity = this.cityTarget.value
  }

  updateFields() {
    const disabled = this.inputTarget.disabled
    this.selectionTarget.disabled = disabled
    this.otherFieldTarget.hidden = !this.otherSelected
    this.otherTarget.disabled = disabled || !this.otherSelected
    this.otherTarget.required = !this.otherTarget.disabled
    this.cityFieldTarget.hidden = !this.otherSelected
    this.cityTarget.disabled = disabled || (!this.selected && !this.otherSelected)
    this.cityTarget.required = !this.cityTarget.disabled
    this.inputTarget.setCustomValidity(!disabled && this.inputTarget.value && !this.selected && !this.otherSelected ? this.chooseValue : "")
  }

  revealCity() {
    this.cityFieldTarget.hidden = false
  }

  open(event) {
    if (this.inputTarget.disabled) return
    if (event?.type === "focus" && !this.listTarget.hidden) return
    const query = this.otherSelected ? "" : this.inputTarget.value
    const words = this.normalize(query).trim().split(/\s+/).filter(Boolean)
    const courts = this.options.filter((option) => words.every((word) => option.normalized.includes(word)))
    this.matches = [...courts, { label: this.otherValue, other: true }]
    this.active = -1
    this.listTarget.replaceChildren(...this.matches.map((option, index) => {
      const element = document.createElement("li")
      element.id = `${this.listTarget.id}-${index}`
      element.role = "option"
      element.setAttribute("aria-selected", "false")
      element.dataset.index = index
      if (option.other) element.dataset.other = "true"
      element.dataset.action = "pointerdown->court-picker#keepFocus click->court-picker#choose"
      element.textContent = option.label
      return element
    }))
    this.listTarget.hidden = false
    this.statusTarget.textContent = courts.length ? this.countValue.replace("%{count}", courts.length) : this.emptyValue
    this.statusTarget.hidden = false
    this.inputTarget.setAttribute("aria-expanded", "true")
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
    if (option.other) {
      if (this.selected && this.cityTarget.value === this.selectedCity) this.cityTarget.value = ""
      this.selected = null
      this.otherSelected = true
      this.inputTarget.value = this.otherValue
      this.selectionTarget.value = "__other__"
      this.updateFields()
      this.close()
      this.inputTarget.dispatchEvent(new Event("change", { bubbles: true }))
      this.otherTarget.focus()
      return
    }
    this.otherSelected = false
    this.inputTarget.value = option.label
    this.selectionTarget.value = option.label
    this.cityTarget.value = option.city
    this.selected = option
    this.selectedLabel = option.label
    this.selectedCity = option.city
    this.updateFields()
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
    if (this.element.contains(event.relatedTarget) || this.listPointerDown || this.listTarget.matches(":hover")) return
    this.close()
  }

  beginPointer() {
    this.listPointerDown = true
  }

  finishPointer() {
    if (!this.listPointerDown) return
    this.listPointerDown = false
    if (!this.listTarget.hidden && document.activeElement !== this.inputTarget) {
      this.inputTarget.focus({ preventScroll: true })
    }
  }

  outside(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  kindChanged(event) {
    if (event.target.matches('input[name$="[kind]"]')) {
      this.updateFields()
      this.close()
    }
  }

  close() {
    this.listPointerDown = false
    this.listTarget.hidden = true
    this.statusTarget.hidden = true
    this.inputTarget.setAttribute("aria-expanded", "false")
    this.inputTarget.removeAttribute("aria-activedescendant")
    this.active = -1
  }
}
