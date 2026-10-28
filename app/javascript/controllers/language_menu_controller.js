import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  close(event) {
    if (!this.element.open) return
    this.element.open = false
    if (event?.key === "Escape") this.element.querySelector("summary").focus()
  }

  closeOutside(event) {
    if (!this.element.contains(event.target)) this.close()
  }

  closeOnFocusOut(event) {
    if (event.relatedTarget && !this.element.contains(event.relatedTarget)) this.close()
  }
}
