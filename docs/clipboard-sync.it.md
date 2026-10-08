### Sincronizzazione appunti con iPhone

Cocaine non ha un'app per iPhone e non usa CloudKit di Apple (servirebbe un account sviluppatore Apple). Le copie viaggiano lo
stesso tra iPhone e Mac in tre modi, che funzionano insieme. Tutto ciò che segue è **spento di default**; gli interruttori sono in
*Impostazioni → Isola → Sincronizzazione appunti con iPhone*.

| | Cosa | Fin dove | Cifrato end-to-end | Configurazione |
|---|---|---|---|---|
| **Appunti universali** (di Apple) | testo, immagini | dispositivi vicini, per poco | quello di Apple | niente (Handoff attivo) |
| **Cartella iCloud Drive** | testo, link, immagini | ovunque, da secondi a minuti | solo con la Protezione avanzata dei dati | attivala + due Comandi Rapidi |
| **iPhone abbinato (relay)** | testo breve (≈ 2.000 caratteri) | ovunque, pochi secondi | sì | un iPhone abbinato + un Comando Rapido |

#### 1. Cartella iCloud Drive

Attiva *Sincronizza con iCloud Drive*. Cocaine crea una cartella **iCloud Drive › Shortcuts › Cocaine Clipboard** (su questo
Mac: `~/Library/Mobile Documents/iCloud~is~workflow~my~workflows/Documents/Cocaine Clipboard/`) con `inbox/` (iPhone → Mac) e
`outbox/` (Mac → iPhone). Sta nella cartella iCloud dell'app Comandi Rapidi perché è l'unico posto che un Comando Rapido su
iPhone può raggiungere con un percorso, senza che tu scelga una cartella sul telefono.

*Aggiungi…* accanto a *Comandi Rapidi per iPhone* crea, firma e apre due Comandi Rapidi nell'app Comandi Rapidi di questo Mac;
arrivano all'iPhone tramite iCloud come tutti i tuoi Comandi Rapidi:

- **Invia al Mac** — nel menu Condividi per testo, link e immagini; avviato da solo (widget, Siri, Tocco posteriore) prende gli
  appunti dell'iPhone. Salva un file con nome univoco in `inbox/`. Sul Mac l'elemento compare nella cronologia degli appunti
  segnato *Dal tuo iPhone* (un piccolo simbolo di iPhone), se vuoi fissato in una bacheca a scelta e messo negli appunti del Mac
  (*Mettilo negli appunti attuali*).
- **Ricevi dal Mac** — mette negli appunti dell'iPhone l'elemento più recente inviato dal Mac (un'immagine vince su un testo). Sul
  Mac invia un elemento con **Invia all'iPhone** nel suo menu o nella barra della selezione; *Invia ogni copia* (spento di default)
  invia ogni nuova copia.

Come il Mac gestisce la cartella: osserva `inbox/` (eventi della cartella, più un controllo ogni 2 secondi mentre arriva un file, altrimenti ogni 20), prende un file solo
quando la sua dimensione ha smesso di cambiare (scritture a metà e download in corso restano lì), ignora file temporanei e
nascosti, chiede a iCloud i file che sono solo segnaposto (`.nome.icloud`) e dopo 3 minuti li conta come *in attesa di iCloud*,
prende una volta sola lo stesso contenuto arrivato due volte, rifiuta senza leggerli i file oltre 25 MB (testo oltre 1 MB) e li
mette da parte in `processed/`, rimpicciolisce le foto (lato lungo 2.048 pixel, salvate in PNG come ogni immagine copiata),
riconosce le immagini dai loro byte (qualunque nome abbia il file) e cancella ogni file una volta preso (o lo tiene in
`processed/` con *Conserva i file ricevuti*). I file vecchi in `processed/` e quelli di Cocaine in `outbox/` vengono rimossi dopo
un giorno. *Prova* scrive un piccolo file nella cartella, lo rilegge e lo rimuove.

Ciò che arriva passa per le regole degli appunti: chiavi, token e numeri di carta vengono saltati (con *Salta numeri di carta e
chiavi*), così i tuoi modelli esclusi e ciò che è troppo grande. Anche ciò che parte è controllato: **mai** ciò che sembra una
password, una chiave o un numero di carta (qualunque cosa dica l'impostazione), mai i tuoi modelli esclusi, mai copie di app
escluse o di gestori di password, mai file (arriverebbero solo i nomi), e *Invia ogni copia* non rimanda mai ciò che è arrivato
da un dispositivo.

**Limiti.** La cartella è nel tuo iCloud Drive: è cifrata end-to-end solo se hai attivato la Protezione avanzata dei dati di
iCloud; altrimenti le chiavi le ha Apple. La velocità la decide iCloud: di solito secondi, a volte minuti; Risparmio energetico e
*Ottimizza spazio del Mac* possono rallentarla. iCloud Drive deve essere attivo su entrambi i dispositivi. Al primo avvio di ogni
Comando Rapido l'iPhone chiede di consentire l'accesso al file. macOS può chiedere una volta se Cocaine può usare iCloud Drive.
Se invii un testo subito dopo un'immagine, aspetta qualche secondo prima di *Ricevi dal Mac*, o vedrà ancora l'immagine come la
più recente.

#### 2. Testo breve tramite l'iPhone abbinato (cifrato end-to-end)

Se hai abbinato un iPhone per il lavoro da remoto (*Impostazioni → Lavoro da remoto → iPhone*), può anche scambiare testo breve con
gli appunti, sullo stesso relay e con lo stesso protocollo (autenticato, cifrato end-to-end, a prova di replay: vedi
[remote-security](remote-security.it.md)). Due interruttori per ogni iPhone abbinato, entrambi spenti: *Consenti all'iPhone … di
leggere i miei appunti* e *… di inviare testo ai miei appunti*. *Aggiungi… → Cocaine Clip* crea un piccolo Comando Rapido a parte
per quell'iPhone (contiene la chiave dell'abbinamento: invialo come il Comando Rapido remoto, per esempio con AirDrop). Il suo menu:

- **Invia i miei appunti** — il testo dell'iPhone va nella cronologia del Mac (fino a 6 parti cifrate, circa 2.000 caratteri; più
  lungo: usa *Invia al Mac*).
- **Ricevi l'ultimo dal Mac** — l'elemento più recente della cronologia va negli appunti dell'iPhone; tagliato a circa 2.700 byte
  (e lo dice).
- **Elenca la bacheca per iPhone** / **Ricevi un elemento della bacheca…** — la bacheca scelta in *Bacheca leggibile
  dall'iPhone*, per numero.

Il Mac risponde a questi comandi `clip` dentro l'app, mai tramite una shell (il gate remoto li rifiuta). Funzionano solo per
abbinamenti v2 (mai per i vecchi Comandi Rapidi in chiaro), a entrambi i livelli, al massimo 12 al minuto per iPhone. La lettura
dà solo l'elemento più recente o la bacheca leggibile — mai il resto della cronologia — e mai ciò che sembra un segreto
(un'immagine o un file rimandano alla via iCloud). Le parti di un testo lungo devono arrivare tutte entro 2 minuti, con numeri
coerenti, o il testo viene scartato. Le immagini non passano di qui: il Comando Rapido dovrebbe cifrarle con azioni di hash,
troppo lentamente.

#### 3. Appunti universali (di Apple)

Con lo stesso Account Apple, Bluetooth, Wi-Fi e Handoff attivi, una copia fatta su un iPhone o iPad vicino si può incollare sul
Mac (e viceversa). Cocaine segna queste copie *Un altro dispositivo* (macOS le marca; l'app in primo piano non ne prende il merito)
e *Copie da altri dispositivi* nelle impostazioni degli Appunti (spento di default dalla 2.9: queste copie non vengono nemmeno lette)
le include. Novità: *Non salvare le sue copie nella
cronologia* le tiene solo in memoria anche quando la cronologia è salvata su questo Mac (quelle fissate in bacheca restano
salvate). Cercando `from:iphone` (o `from:device`) trovi sia queste sia gli elementi della sincronizzazione con iPhone.

Ciò che Cocaine mette negli appunti (clic su un elemento, *Mettilo negli appunti attuali*) è una normale scrittura negli appunti.
Apple non documenta alcun modo, per un'app Mac, di tenere una scrittura fuori dagli Appunti universali (iOS ha un'opzione "solo
locale", macOS nessuna pubblica), quindi Cocaine non ci prova: che Handoff offra queste scritture a un iPhone vicino è atteso ma
**non verificato** su un dispositivo.

#### Cosa è stato verificato, e cosa no

- Testato con simulazioni (`--clipsync-test`, 145 controlli): l'osservatore della cartella su cartelle temporanee (segnaposto,
  scritture a metà, duplicati, file grandi e vuoti, un livello di sottocartelle, rimozione, pulizia), cosa diventano i file,
  l'ingresso in una cronologia, il filtro in uscita, i comandi del relay con ogni permesso, le parti e i loro casi limite, il
  limite di frequenza, replay e manomissioni attraverso il protocollo v2 e il listener, il rifiuto del gate, e i tre Comandi
  Rapidi eseguiti in un simulatore dell'app Comandi Rapidi (testo, Unicode, vuoto, lungo, un'immagine, nessun input) in ogni
  lingua dell'app.
- Su questo Mac: i tre Comandi Rapidi sono stati firmati da `shortcuts sign` di Apple; la cartella iCloud di Comandi Rapidi esiste
  e il suo stato iCloud si legge senza entitlement.
- **Non verificato** su un iPhone: Salva file / Ottieni file per percorso dei Comandi Rapidi generati (la cartella Shortcuts è
  quella dove Comandi Rapidi mette i file di default), *Se … ha un valore*, *Ripeti* e l'input dal menu Condividi; se
  `startDownloadingUbiquitousItem` scarica un file rimosso dal disco per un'app firmata come Cocaine; se Handoff propone le
  scritture negli appunti fatte da Cocaine. I nomi delle azioni e dei parametri vengono dalle definizioni delle azioni di Comandi
  Rapidi su macOS 27, non da un'esecuzione su un telefono.

**Non costruito, di proposito:** sincronizzazione CloudKit o iCloud dell'intera cronologia (serve un account sviluppatore), un'app,
una tastiera o un widget per iPhone, immagini o testi lunghi tramite il relay (il telefono non riesce a cifrarli in tempo, e in
chiaro romperebbe la promessa), S3 o WebDAV (catene di firme che Comandi Rapidi non sa fare, o un server che vede il testo in
chiaro), e una passphrase per cifrare i file su iCloud (sull'iPhone servirebbe lo stesso cifrario lento a base di hash del relay;
per un testo che deve essere end-to-end, usa il relay).
