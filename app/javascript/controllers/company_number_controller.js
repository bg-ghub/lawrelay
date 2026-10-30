import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["enterprise", "vat", "lookup"]
  static values = { locale: { type: String, default: "nl" } }

  connect() {
    this.sync()
  }

  sync() {
    const raw = this.enterpriseTarget.value.toUpperCase().trim()
    const withoutBelgianPrefix = raw.replace(/^BE(?=[\s.\d-]*$)/, "")
    const number = withoutBelgianPrefix.replace(/[.\s-]/g, "")

    if (/^\d*$/.test(number)) {
      this.enterpriseTarget.value = number
      this.vatTarget.value = /^\d{10}$/.test(number) ? `BE ${number}` : ""
    } else {
      this.enterpriseTarget.value = raw
      this.vatTarget.value = ""
    }

    if (this.hasLookupTarget) {
      const valid = /^\d{10}$/.test(number) && Number(number.slice(8)) === 97 - (Number(number.slice(0, 8)) % 97)
      this.lookupTarget.setAttribute("aria-disabled", String(!valid))
      if (valid) {
        const locale = ["nl", "fr", "de", "en"].includes(this.localeValue) ? this.localeValue : "nl"
        this.lookupTarget.href = `https://kbopub.economie.fgov.be/kbopub/toonondernemingps.html?ondernemingsnummer=${number}&lang=${locale}`
      } else {
        this.lookupTarget.removeAttribute("href")
      }
    }
  }
}
