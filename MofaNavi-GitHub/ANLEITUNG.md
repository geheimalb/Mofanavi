# IPA bauen mit GitHub (kostenlos, ohne Mac)

1. Kostenloses Konto auf github.com anlegen.
2. Neues Repository erstellen (Private reicht).
3. Dateien hochladen: "Add file → Upload files". Den Ordner `MofaNavi` (mit den .swift-Dateien) und `project.yml` hochladen.
4. Die Build-Datei anlegen: "Add file → Create new file", als Namen exakt
   `.github/workflows/build.yml` eingeben und den Inhalt der Datei `build.yml` aus diesem Paket einfügen.
5. Reiter "Actions" öffnen, "Build IPA" wählen, "Run workflow" drücken. Dauert ca. 5 bis 10 Minuten.
6. Nach dem Lauf unten bei "Artifacts" `MofaNavi-ipa` herunterladen und die .ipa aus dem ZIP entpacken.
7. Mit Sideloadly oder AltStore und deiner Apple-ID aufs iPhone installieren (läuft 7 Tage, danach neu signieren).

Wenn der Build rot wird: auf den Lauf klicken, die Fehlermeldung kopieren und mir schicken.
