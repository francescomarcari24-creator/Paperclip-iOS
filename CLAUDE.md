# CLAUDE.md — Paperclip iOS

Questo file documenta l'architettura, le convenzioni e lo stato di sincronizzazione della versione **iOS nativa (Swift + SwiftUI)** di **Paperclip** rispetto al repository Android principale (`C:\Users\franc\AndroidStudioProjects\Paperclip`).

## Stato Sincronizzazione con Android

- **Repository Android locale:** `C:\Users\franc\AndroidStudioProjects\Paperclip`
- **Repository Android remoto:** `https://github.com/francescomarcari24-creator/Paperclip.git`
- **Ultimo commit Android sincronizzato (`LAST_SYNCED_ANDROID_COMMIT`):** `99d8319` (*"Sincronizzazione senza Wi-Fi: permessi chiesti, niente posizione, Wi-Fi mai riacceso, ripiego su Nearby"*)

### Come sincronizzare nuove funzioni da Android a iOS
1. Aggiornare il repo Android o fare `git fetch android` in questo repo.
2. Controllare le modifiche intervenute su Android dal commit `99d8319`:
   ```powershell
   git -C C:\Users\franc\AndroidStudioProjects\Paperclip log 99d8319..HEAD --oneline
   git -C C:\Users\franc\AndroidStudioProjects\Paperclip diff 99d8319..HEAD -- app/ CLAUDE.md
   ```
3. Portare le stesse modifiche nei file Swift corrispondenti dentro `Paperclip/` e aggiornare `LAST_SYNCED_ANDROID_COMMIT` qui sopra.

---

## Compilazione e Sideload da Windows (senza Mac)

1. **XcodeGen (`project.yml`):**
   - Il progetto Xcode viene generato automaticamente da `project.yml` nella radice del repository.
   - Qualsiasi nuovo file `.swift` o risorsa inserito in `Paperclip/` viene incluso automaticamente nella build senza dover modificare `.pbxproj`.
2. **GitHub Actions (`.github/workflows/ios.yml`):**
   - Ad ogni push su `main`/`master` (o tramite avvio manuale `workflow_dispatch`), GitHub Actions avvia un runner `macos-latest`, esegue `xcodegen generate`, compila l'app per `generic/platform=iOS` con `CODE_SIGNING_ALLOWED=NO`, impacchetta `Payload/Paperclip.app` in **`Paperclip.ipa`** e lo carica come Artifact.
3. **Installazione su iPhone 13 (iOS 27):**
   - Scaricare l'artifact `Paperclip-iOS-IPA` da GitHub Actions, estrarre `Paperclip.ipa` e installarlo sull'iPhone 13 tramite **Sideloadly** (o **SideStore**) usando il proprio Apple ID.

---

## Architettura e Compatibilità Dati 100% con Android

- **Lingua UI:** tutte le stringhe visibili all'utente sono in **italiano**, cablate direttamente nel codice Swift.
- **Tema e Colori (`Theme/PaperclipTheme.swift`):**
  - Supporta `ThemeMode` (`LIGHT`, `SYSTEM`, `DARK`) e tutte le 12 varianti di `AccentColor` (da `SYSTEM` a `RED`..`PINK`) con transizione cross-fade animata di `450 ms` (`0.45 s`).
- **Database SQLite (`Data/PaperclipDatabase.swift`):**
  - Schema SQLite nativo identico a Room v6 (`paperclip_database.sqlite`):
    - `archive_items` (tabella polimorfica per `LINK`, `PHOTO`, `VIDEO`, `AUDIO`, `NOTE`, `CHECKLIST`, `DRAWING`, `PDF`)
    - `folders` (con `parentId` senza foreign key e gerarchia `FolderTree` anti-ciclo)
    - `tags`
    - `item_tag_cross_ref`
    - `item_content` (`sourceKey`, `text`, `articleJson`, `indexedAt`, `attempts`, `attemptedAt`)
  - Soft-delete nel cestino (`deletedAt`, pulizia automatica dopo `TRASH_DAYS = 30`).
- **Backup `.zip` e Crittografia `PCLIPENC` (`Backup/BackupManager.swift`, `Backup/BackupCrypto.swift`):**
  - Compatibilità binaria totale con `BackupManager.kt` e `BackupCrypto.kt`:
    - Archivio ZIP con `backup_data.json` + cartella `media/<nomefile>`.
    - Riscrittura automatica dei percorsi `/media/<nomefile>` alla directory locale `Documents/media/` in fase di importazione e ricalcolo `sourceKey` di `ItemContent`.
    - Formato cifrato `PCLIPENC`: header `PCLIPENC` (8 byte) + versione `1` (1 byte) + iterazioni big-endian (`200_000`, 4 byte) + salt (16 byte) + nonce prefix (8 byte) + blocchi da 64 KB cifrati con AES-GCM-256 (chiave PBKDF2-HMAC-SHA256, nonce = `noncePrefix + chunkIndex`, AAD = `0x00` o `0x01` per l'ultimo chunk).
    - Password di backup custodita nel **Keychain** iOS.
