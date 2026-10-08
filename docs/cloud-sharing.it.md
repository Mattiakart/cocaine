### Condivisione cloud e link (scaffale)

Seleziona dei file sullo scaffale, scegli **Condividi link…** e un servizio: Cocaine li carica (più file o una cartella
vengono prima compressi in ZIP con `ditto`), mette il link negli appunti e lo mostra sotto lo scaffale con **Copia link**,
**Apri** e **Revoca**. Il caricamento è un lavoro dello scaffale, con barra di avanzamento e **Annulla**.

I servizi si configurano in **Impostazioni → Isola → Condivisione**. Niente è configurato al posto tuo, nessun host pubblico è
incluso e nulla viene mai caricato senza un clic: cartelle osservate, azioni istantanee, link e riga di comando non caricano mai.

#### Servizi

| Servizio | Come | Link | Revoca |
|---|---|---|---|
| **Compatibili S3**: Amazon S3, Cloudflare R2, Backblaze B2, Wasabi, DigitalOcean Spaces, MinIO | Il tuo endpoint, regione, bucket e chiavi. Un PUT firmato (AWS Signature V4, scritta con CryptoKit), letto dal file in streaming. Oltre 100 MB il file sale a parti (multipart); se annullato o fallito viene interrotto, così nel bucket non resta un caricamento a metà. Fino a 50 GB. | Un link **prefirmato** che scade (1 h, 24 h — predefinito —, 3 giorni o 7 giorni, il massimo di S3), oppure un link sotto il tuo **indirizzo pubblico** (bucket pubblico, r2.dev o tuo dominio), che non scade. | Elimina l'oggetto: il link smette di funzionare. |
| **Nextcloud / ownCloud** | Server, nome utente e una **password per app**. Il file va in una cartella (predefinita *Cocaine*, creata se manca) via WebDAV. Fino a 4 GB. | Un link pubblico di sola lettura creato con l'API di condivisione OCS, con password ed eventuale scadenza (1, 7 o 30 giorni, o mai). | Elimina la condivisione, poi il file. |
| **WebDAV** (qualsiasi server: Synology, Apache, Fastmail…) | Indirizzo WebDAV della cartella, nome utente e password. Fino a 4 GB. | Il tuo indirizzo pubblico per quella cartella + il nome del file; senza, l'indirizzo WebDAV stesso (chiede il login). | Elimina il file. |
| **SFTP** (tuo server) | `/usr/bin/sftp` **solo con chiavi**: ssh-agent o un file di chiave. Fino a 50 GB. | L'indirizzo web pubblico della cartella remota + il nome del file. | Rimuove il file. |
| **Il tuo comando di caricamento** | Una riga di comando tua (curl o uno script) che carica `{file}` e stampa il link. Fino a 2 GB. | Il primo link https stampato, un'espressione regolare o un percorso JSON. | Non possibile (decide il servizio). |

Non inclusi: link di Google Drive, OneDrive e iCloud Drive (richiedono la registrazione dell'app presso Google o Microsoft, o
CloudKit con un account sviluppatore Apple), Imgur e accorciatori di link (tracciamento di terzi), host pubblici anonimi
(0x0.st, file.io, transfer.sh, Litterbox) — Litterbox è solo un *modello* modificabile per il tuo comando, con un avviso.
Nemmeno **Dropbox** è incluso: una versione pulita richiede che ogni utente registri la propria app Dropbox e un listener
OAuth locale (una porta in ascolto), che questa app non apre; puoi comunque caricare su Dropbox con un tuo script come
*il tuo comando di caricamento*.

#### Configurazione

**Aggiungi…** offre i modelli S3 (forma dell'endpoint e regione già compilate), Nextcloud, WebDAV, SFTP, il tuo comando e i
suoi modelli (Zipline, un tuo endpoint, uno script, Litterbox). Ogni servizio ha **Prova connessione**: carica un piccolo file
generato, apre il suo link (link S3 prefirmati) e lo elimina. L'interruttore accanto a ogni servizio lo nasconde dallo
scaffale; l'interruttore **Condivisione cloud** in alto spegne tutto.

- **S3 / R2**: crea una chiave che possa solo scrivere (ed eliminare) in quel bucket. L'endpoint di R2 è
  `https://<account-id>.r2.cloudflarestorage.com` con regione `auto`. Gli oggetti si chiamano
  `<prefisso>/<32 caratteri esadecimali casuali>/<nome sicuro>`, quindi i link non si indovinano. *Indirizzi path-style* è
  attivo per R2, B2 e MinIO; spegnilo per AWS e Spaces se il bucket vuole `bucket.endpoint`.
- **Payload non firmato**: il corpo viene inviato con `x-amz-content-sha256: UNSIGNED-PAYLOAD` (ammesso su TLS), così un file
  grande va in streaming senza essere letto due volte. Se un servizio lo rifiuta, Cocaine calcola l'hash del file, lo
  rimanda e da allora lo fa sempre per quel servizio. Le parti di un multipart hanno sempre l'hash.
- **Nextcloud**: crea una password per app in Impostazioni → Sicurezza → Dispositivi e sessioni.
- **SFTP**: il server deve già essere in `~/.ssh/known_hosts` (collegati una volta con `ssh` dal Terminale e controlla la
  chiave): Cocaine avvia `sftp` con `BatchMode=yes`, `StrictHostKeyChecking=yes`, login con password e interattivi spenti.
  La cartella remota deve esistere.
- **Il tuo comando**: segnaposto `{file}` (obbligatorio), `{name}`, `{mime}`, `{size}`, `{secret_headers}`. Esempio:
  `/usr/bin/curl -sS --fail -H @{secret_headers} -F "file=@{file}" https://upload.example.com/`. Parte solo dopo che hai
  autorizzato quel comando esatto (e lo script che nomina); lo richiede se uno dei due cambia.

#### Privacy e sicurezza

- **Segreti** (chiavi S3, password, token, header segreti) stanno nel Portachiavi, servizio `local.cocaine.share`, un elemento
  per servizio, leggibili solo a Mac sbloccato, solo su questo Mac, mai sincronizzati. Il file delle impostazioni
  (`~/Library/Application Support/Cocaine/share/providers.json`, 0600) non contiene segreti. Un campo segreto mostra
  "Salvato nel Portachiavi" e non viene più mostrato; scrivere lo sostituisce. Rimuovere un servizio elimina il suo elemento.
- **Solo TLS**: ogni indirizzo deve essere `https://` (`http://` solo verso questo Mac, per un MinIO locale). Un indirizzo con
  nome utente o password dentro è rifiutato. I redirect non vengono mai seguiti con le tue credenziali. Le risposte sono limitate.
- **Ogni caricamento è un clic.** I nuovi servizi chiedono **prima di ogni caricamento** (dove vanno i file e per quanto vale
  il link); si può spegnere per servizio. Il tuo comando chiede anche prima della prima esecuzione.
- **I link sono password.** Chi ha il link può scaricare il file finché non scade o lo revochi. I link vanno negli appunti
  come una copia normale (dalla 2.9; prima marcati *nascosti*, il che può tenere la copia lontana anche dagli altri tuoi
  dispositivi): la cronologia appunti di Cocaine non li tiene; le altre app di appunti e gli Appunti universali li trattano come
  ogni copia.
- **Niente nei log**: né segreti né URL firmati; i messaggi d'errore nominano al massimo l'host.
- **Nomi dei file** resi sicuri per chiavi e percorsi (lettere, cifre, `.`, `_`, `-`); la cronologia tiene il nome originale.
  Il Content-Type viene dal tipo del file.
- **Il tuo comando** gira senza shell: la riga è divisa in argomenti, i segnaposto riempiti in ciascuno, e il file passato come
  link con un nome sicuro in una cartella temporanea privata, così un nome come `$(rm -rf ~)` o `-o x` è un percorso innocuo.
  Ha un ambiente minimo, un timeout di 5 minuti e un output limitato; gli header segreti vanno in un file temporaneo 0600
  (`{secret_headers}`, anche `$COCAINE_SECRET_FILE`), mai negli argomenti o nell'ambiente.
- **Cronologia** (`share/history.json`, 0600, al massimo 200 voci): nome, dimensione, servizio, data, scadenza e link — mai il
  file. **Rimuovi scaduti** toglie i link scaduti e revocati; le voci si tolgono una a una o tutte.

#### Azioni personalizzate: webhook, tasti, catene, import/export

- **Webhook** (Impostazioni → Isola → Scaffale → Le tue azioni → Aggiungi… → Webhook): invia con POST o PUT i file selezionati
  (una richiesta ciascuno, con `X-Cocaine-Filename`) o i loro dettagli in JSON (nomi, dimensioni, tipi, date; nessun percorso)
  al tuo indirizzo https. Un header segreto (es. `Authorization: Bearer …`) sta nel Portachiavi. Chiede prima della prima
  esecuzione e di nuovo se cambiano indirizzo, metodo o contenuto. La risposta può andare negli appunti o sullo scaffale.
- **Tasti**: assegna a un'azione ⌥1…⌥9; quando lo scaffale ha la tastiera, quel tasto la esegue sulla selezione (o su tutta
  la raccolta).
- **Poi**: un'azione può passare il risultato a un'altra — i file che ha stampato (un percorso per riga) o spostato,
  altrimenti gli stessi file. Al massimo 4 passi, mai in cerchio; ogni azione chiede comunque prima della sua prima esecuzione.
- **Importa… / Esporta…** salva le azioni in JSON senza autorizzazioni né segreti; quelle importate hanno nuovi id, mantengono
  le catene, perdono i tasti già usati e chiedono prima della prima esecuzione.

#### Limiti

- Verificato solo contro server finti locali (`--cloud-test`): la SigV4 di S3 con gli esempi pubblicati da AWS, PUT,
  multipart, link prefirmati, il ripiego sul payload firmato, WebDAV, l'API di condivisione di Nextcloud, gli argomenti di SFTP
  (mai eseguito verso un host). Non ancora provato con R2, B2, Wasabi, Spaces, Nextcloud o un server SFTP reali: se un
  servizio accetta UNSIGNED-PAYLOAD lo gestisce il ripiego automatico.
- Al massimo 100 file per caricamento (più file diventano un solo ZIP, quindi un solo link). Un caricamento alla volta, con
  gli altri lavori dello scaffale.
- Niente caricamenti ripresi; un multipart S3 annullato viene interrotto, un caricamento SFTP annullato, scaduto o fallito a
  metà viene rimosso, un PUT WebDAV interrotto non lascia nulla sulla maggior parte dei server. Un caricamento SFTP può durare
  un'ora, o di più per un file grande (si conta su almeno 1 MB/s).
- **Revoca** elimina il file dove è stato caricato: se nel frattempo bucket, cartella o server del servizio sono cambiati,
  Cocaine lo dice invece di non eliminare nulla (elimina il file direttamente sul servizio). Annulla ferma tutto il comando
  del caricatore, compresi i programmi avviati dal suo script.
- Il servizio SFTP non usa ancora l'elenco host SSH delle sessioni remote; il server si inserisce qui.
