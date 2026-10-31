# KBO lookup

Uses the public KBO page by enterprise number, following Praxis's working lookup. No additional account, credentials or service is needed. The SOAP endpoint was checked separately and requires WS-Security authentication; it is not used here.

The button makes one targeted server-side request and previews the legal name and available registered-office address. Saving remains explicit. It imports no email, phone, bank details, officials or establishment address. A natural-person record can omit its address; that stays manual.

Recognized legal forms appear before the name, such as BV BG Legal. An explicit natural-person record uses NP. Unknown forms stay unchanged.

Requests use a fixed government HTTPS host, TLS verification, a 15-second limit and bounded HTML. Redirects, CAPTCHA and block pages fail safely. There is no registry-wide collection or response cache. Interactive lookup limits are five requests per minute per IP and 2,000 per 24 hours. Manual entry remains available.

The existing server checks entered numbers daily, once per distinct number, alongside members' advocaat.be profiles. It reports an explicit KBO `Stopgezet` result separately from missing, unknown or unavailable pages. New issues appear in admin and in one operator email; unchanged issues do not generate repeated mail. This monitoring does not alter billing details or account access.

The app stores the KBO source snapshot date and names of unchanged imported fields. This does not verify the lawyer or grant account access. Source: [KBO Public Search](https://kbopub.economie.fgov.be/kbopub/zoeknummerform.html?lang=nl).
