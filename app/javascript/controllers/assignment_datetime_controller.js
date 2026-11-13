import { Controller } from "@hotwired/stimulus"

const DATE_PREFIX = /^(\d{1,2})\/(\d{1,2})\/(\d{4})(?:\s|$)/
const TIME_SUFFIX = /(?:^|\s)(\d{1,2}:\d{0,2})\s*$/
const BRUSSELS_CLOCK = new Intl.DateTimeFormat("en-GB", {
  timeZone: "Europe/Brussels", year: "numeric", month: "2-digit", day: "2-digit",
  hour: "2-digit", minute: "2-digit", hourCycle: "h23"
})

function brusselsTime() {
  const { year, month, day, hour, minute } = Object.fromEntries(
    BRUSSELS_CLOCK.formatToParts().map(({ type, value }) => [type, value])
  )
  return { date: new Date(`${year}-${month}-${day}T00:00:00Z`), hour, minute }
}

export default class extends Controller {
  static targets = ["input", "toggle", "picker", "month", "days", "hour", "minute", "apply"]

  connect() {
    if (!this.pickerTarget.showPopover) return

    const locale = this.element.closest("[lang]").lang
    this.monthFormat = new Intl.DateTimeFormat(locale, { month: "long", year: "numeric", timeZone: "UTC" })
    this.dayFormat = new Intl.DateTimeFormat(locale, { dateStyle: "full", timeZone: "UTC" })
    this.weekdayFormat = new Intl.DateTimeFormat(locale, { weekday: "short", timeZone: "UTC" })
    this.pickerTarget.hidden = false
    this.toggleTarget.hidden = false
  }

  close() {
    this.pickerTarget.hidePopover?.()
  }

  prepare(event) {
    if (event.newState !== "open") return

    const today = brusselsTime().date
    const parts = this.inputTarget.value.trim().match(DATE_PREFIX)
    this.selectedDay = null
    if (parts) {
      const [, day, month, year] = parts.map(Number)
      const selected = new Date(Date.UTC(year, month - 1, day))
      if (selected.getUTCFullYear() === year && selected.getUTCMonth() === month - 1 && selected.getUTCDate() === day) {
        this.selectedDay = selected
      }
    }
    this.applyTarget.disabled = !this.selectedDay
    const [hour = "", minute = ""] = this.inputTarget.value.match(TIME_SUFFIX)?.[1].split(":") || []
    this.hourTarget.selectedIndex = Number(hour) < 24 ? Number(hour) : 0
    this.minuteTarget.selectedIndex = Number(minute) < 60 ? Number(minute) : 0
    this.showMonth(this.selectedDay || today)
  }

  showMonth(date) {
    this.displayMonth = new Date(date)
    this.displayMonth.setUTCDate(1)
    this.render()
  }

  previous() { this.moveMonth(-1) }
  next() { this.moveMonth(1) }

  today() {
    this.selectShortcutDate(brusselsTime().date)
  }

  now() {
    const { date, hour, minute } = brusselsTime()
    this.hourTarget.value = hour
    this.minuteTarget.value = minute
    this.selectShortcutDate(date)
  }

  selectShortcutDate(date) {
    this.selectedDay = date
    this.applyTarget.disabled = false
    this.showMonth(date)
  }

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

    this.selectedDay = new Date(`${button.dataset.day}T00:00:00Z`)
    this.daysTarget.querySelector('[aria-pressed="true"]')?.setAttribute("aria-pressed", "false")
    button.setAttribute("aria-pressed", "true")
    this.applyTarget.disabled = false
  }

  apply() {
    if (!this.selectedDay || this.inputTarget.disabled) return

    const [year, month, day] = this.selectedDay.toISOString().slice(0, 10).split("-")
    const time = `${this.hourTarget.value}:${this.minuteTarget.value}`
    this.inputTarget.value = `${day}/${month}/${year} ${time}`
    this.inputTarget.dispatchEvent(new Event("input", { bubbles: true }))
    this.inputTarget.dispatchEvent(new Event("change", { bubbles: true }))
    this.close()
    this.toggleTarget.focus()
  }
}
