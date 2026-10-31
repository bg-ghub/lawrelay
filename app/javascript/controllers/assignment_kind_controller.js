import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["legalOnly", "courtOnly", "legalInput", "courtInput", "description"]

  connect() {
    this.update()
  }

  toggle() {
    this.update()
  }

  update() {
    const selectedKind = this.element.querySelector('input[name$="[kind]"]:checked')

    this.element.querySelectorAll(".kind-option").forEach((option) => {
      option.classList.toggle("is-selected", option.contains(selectedKind))
    })

    const isLegalTask = selectedKind?.value === "legal_task"

    this.descriptionTargets.forEach((input) => {
      if (isLegalTask) input.removeAttribute("aria-describedby")
      else input.setAttribute("aria-describedby", "assignment-description-hint")
    })
    this.legalOnlyTargets.forEach((element) => { element.hidden = !isLegalTask })
    this.courtOnlyTargets.forEach((element) => { element.hidden = isLegalTask })
    this.legalInputTargets.forEach((input) => {
      input.disabled = !isLegalTask
      input.required = isLegalTask && input.dataset.required !== "false"
    })
    this.courtInputTargets.forEach((input) => {
      input.disabled = isLegalTask
      input.required = !isLegalTask && input.dataset.required !== "false"
    })
  }
}
