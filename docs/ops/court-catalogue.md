# Court catalogue

`config/courts.be.json` is a bundled snapshot checked on 31 October 2026. Assignment forms do not contact an external service.

The snapshot contains the 317 venues listed across the eight ordinary-court overview lists, plus the Court of Cassation, Constitutional Court and Council of State: 320 options. The justice-of-the-peace list contains 162 cantons and 163 venue links, including the two Philippeville seats. The list includes court divisions and the separate Dutch- and French-speaking Brussels courts. Names are translated for the interface; these labels do not determine the language or jurisdiction of a hearing.

Sources: the [official judicial address directory](https://adresses-judiciaires.just.fgov.be/) links the nine overview pages recorded in `overview_sources`. Each entry retains its individual official source URL. Walloon Brabant and assize seats were checked against the individual court contact pages; the [Court of Cassation](https://www.courdecassation.be/nl/Acces-Toegang.html), [Constitutional Court](https://fr.const-court.be/footer/contacts) and [Council of State](https://www.raadvst-consetat.be/?lang=nl&page=contact) publish their Brussels location.

For updates, compare every overview's court cards and division/canton links with the snapshot, verify changed seats on the individual court page, update `checked_on`, then run `test/models/court_catalogue_test.rb` and `test/system/court_picker_test.rb`. Do not generate combinations of courts and cities: not every court has a division in every city.

The picker searches court type, place and translations without accents. First-instance courts also match family, juvenile, civil and criminal terms; users can add the precise section or a different venue in the same text field. The city remains editable. Other administrative tribunals, notary offices and police interview venues can be entered manually. Existing assignment strings remain valid.
