### Bacheche e snippet (appunti dell'isola)

Le **bacheche** sono raccolte con nome di elementi degli appunti: *Prompt*, *Indirizzi*, *SQL*… **Preferiti** (la stella su
ogni riga) è quella integrata: si può rinominare e ricolorare, non eliminare. Puoi averne fino a 30.

- **Crea**: l'etichetta **+** nell'isola, *Nuova bacheca…* in Impostazioni → Isola → Bacheche, o *Fissa in… → Nuova bacheca…*.
- **Fissa**: trascina una riga (o la selezione) su un'etichetta; *Fissa in…* nella barra della selezione, nei dettagli o tra le
  azioni della riga; la stella per Preferiti. Un elemento può stare in più bacheche; trascinarlo dalla vista di una bacheca
  all'etichetta di un'altra lo sposta.
- **Mostrane una**: clic sulla sua etichetta, ⌥1…⌥9 (⌥0 mostra tutto), ⌘[ e ⌘] per scorrerle. Una bacheca può anche avere una
  **scorciatoia globale** che apre l'isola su di lei (Impostazioni → Isola → Bacheche → la bacheca → *Scorciatoia*; tasti
  rapidi Carbon, nessun permesso).
- **Impostazioni** di ogni bacheca: colore (8), simbolo, l'app in cui è **suggerita per prima** (i suoi elementi vengono per
  primi nell'isola mentre quell'app è in primo piano), scorciatoia, rinomina, sposta su/giù, elimina (i suoi elementi restano
  nella cronologia; quelli che non sono in nessun'altra bacheca tornano soggetti ai limiti della cronologia).

**Gli elementi fissati restano per sempre**: i limiti della cronologia (numero, età, spazio) non li rimuovono mai, *Svuota
cronologia* li tiene, e sono **sempre salvati su questo Mac, cifrati**, anche quando la cronologia è solo in memoria: in
`~/Library/Application Support/Cocaine/clipboard/boards.ccl` (e un file cifrato per ogni immagine o testo formattato),
AES-GCM con la stessa chiave casuale nel tuo Portachiavi di login, file leggibili solo da te. Il primo elemento fissato crea la
chiave (con una build firmata ad hoc macOS può chiedere l'accesso al Portachiavi dopo gli aggiornamenti; se rifiuti, i fissati
restano solo in memoria e la pagina lo dice). *Elimina tutto* elimina anche le bacheche, con i file e la chiave.

**Snippet.** Un testo fissato può diventare uno snippet (l'interruttore in fondo ai suoi dettagli): quando lo incolli, i suoi
segnaposto vengono compilati: `{clipboard}` (ciò che c'è negli appunti in quel momento), `{date}`, `{time}`, `{datetime}`,
`{date:yyyy-MM-dd}` (qualsiasi formato di data) e `{input:Nome}` (Cocaine chiede un valore nell'isola; fino a 5). `{{` e `}}`
sono parentesi letterali; i segnaposto sconosciuti restano come scritti; ciò che un segnaposto inserisce non viene mai espanso
di nuovo. Uno snippet può avere una sua **scorciatoia globale** che lo incolla nell'app in primo piano.

**Non costruito, di proposito**: digitare un'abbreviazione che si espande in uno snippet. Richiederebbe di osservare ogni tasto
in ogni app (Monitoraggio dell'input, la tecnica di un keylogger, che vede anche i campi password), quindi Cocaine non lo fa.
Le bacheche non sono condivise né sincronizzate: niente sincronizzazione iCloud/CloudKit, bacheche condivise o app iOS.
