import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["input", "toggle", "calendar", "month", "days"]
  static values = { today: String }

  connect() {
    if (!this.calendarTarget.showPopover) return

    const locale = this.element.closest("[lang]").lang
    this.monthFormat = new Intl.DateTimeFormat(locale, { month: "long", year: "numeric", timeZone: "UTC" })
    this.dayFormat = new Intl.DateTimeFormat(locale, { dateStyle: "full", timeZone: "UTC" })
    this.weekdayFormat = new Intl.DateTimeFormat(locale, { weekday: "short", timeZone: "UTC" })
    this.calendarTarget.hidden = false
    this.toggleTarget.hidden = false
  }

  close() {
    this.calendarTarget.hidePopover?.()
  }

  prepare(event) {
    if (event.newState !== "open") return

    const today = new Date(`${this.todayValue}T00:00:00Z`)
    const parts = this.inputTarget.value.match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})(?:\s|$)/)
    this.selectedDay = null
    if (parts) {
      const [, day, month, year] = parts.map(Number)
      const selected = new Date(Date.UTC(year, month - 1, day))
      if (selected.getUTCFullYear() === year && selected.getUTCMonth() === month - 1 && selected.getUTCDate() === day) {
        this.selectedDay = selected
      }
    }
    this.displayMonth = new Date(this.selectedDay || today)
    this.displayMonth.setUTCDate(1)
    this.render()
  }

  previous() { this.moveMonth(-1) }
  next() { this.moveMonth(1) }

  moveMonth(offset) {
    this.displayMonth.setUTCMonth(this.displayMonth.getUTCMonth() + offset)
    this.render()
  }

  render() {
    this.monthTarget.textContent = this.monthFormat.format(this.displayMonth)
    const cells = document.createDocumentFragment()
    for (let index = 0; index < 7; index++) {
      const weekday = document.createElement("span")
      // 1 January 2024 was a Monday.
      weekday.textContent = this.weekdayFormat.format(Date.UTC(2024, 0, 1 + index))
      weekday.setAttribute("aria-hidden", "true")
      cells.append(weekday)
    }

    const month = this.displayMonth.getUTCMonth()
    const day = new Date(this.displayMonth)
    const leadingDays = (day.getUTCDay() + 6) % 7
    for (let index = 0; index < leadingDays; index++) cells.append(document.createElement("span"))
    while (day.getUTCMonth() === month) {
      const button = document.createElement("button")
      button.type = "button"
      button.dataset.day = day.toISOString().slice(0, 10)
      button.textContent = day.getUTCDate()
      button.setAttribute("aria-label", this.dayFormat.format(day))
      button.setAttribute("aria-pressed", String(day.getTime() === this.selectedDay?.getTime()))
      cells.append(button)
      day.setUTCDate(day.getUTCDate() + 1)
    }
    this.daysTarget.replaceChildren(cells)
  }

  choose(event) {
    const button = event.target.closest("button[data-day]")
    if (!button) return

    const [year, month, day] = button.dataset.day.split("-")
    const time = this.inputTarget.value.match(/\s+(\d{1,2}:\d{0,2})\s*$/)?.[1] || ""
    this.inputTarget.value = `${day}/${month}/${year} ${time}`
    this.close()
    this.inputTarget.focus()
    this.inputTarget.setSelectionRange(11, this.inputTarget.value.length)
    this.inputTarget.dispatchEvent(new Event("input", { bubbles: true }))
  }
}
