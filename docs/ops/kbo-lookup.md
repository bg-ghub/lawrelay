# KBO lookup — retired

Archived implementation note. Member company lookup and daily KBO monitoring were retired in 0.19.0. Signup, settings and assignments no longer collect member company or invoice details. Lawyers exchange invoicing and Peppol details privately after acceptance. Daily advocaat.be profile checks remain active.

The former lookup made a targeted request to [KBO Public Search](https://kbopub.economie.fgov.be/kbopub/zoeknummerform.html?lang=nl) to preview a legal name and available registered-office address. It used no webservice account and did not verify the lawyer or grant access. KBO-sourced fields and attribution are now covered by `Privacy::CompanyDataCleanup`; retired monitoring targets and summaries are removed.

Recorded holds and historical financial evidence remain protected. Keep historical provider and implementation evidence in the private archive; do not treat it as an active service. The [data register](data-register.md) records current processing and backup retention.
