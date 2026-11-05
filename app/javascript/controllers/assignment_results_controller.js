import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  visit(event) {
    if (event.target !== this.element) return

    event.preventDefault()
    event.detail.visit(event.detail.response)
  }
}
