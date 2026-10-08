### Scaffale (isola)

Lo Scaffale dell'isola tiene a portata di mano ciò che ti serve per un po': **file e cartelle** (come riferimenti a dove
sono, mai copie), **testi**, **link** e **immagini** trascinati o incollati da qualsiasi app (questi ultimi tre li conserva
Cocaine stesso, vedi *Privacy*). Trascinali sul notch: l'isola si apre sullo scaffale e finiscono nella raccolta mostrata (o
nella linguetta della raccolta su cui li lasci).

**Raccolte.** Più scaffali con nome, ognuno con un colore: *Scaffale* è il primo; aggiungine con **+**, passa dall'uno
all'altro con le linguette, e rinominali, cambia colore, ordine, uniscili o eliminali nel pannello delle raccolte (il pulsante
con la pila) o in Impostazioni → Isola → Scaffale. Eliminare una raccolta toglie i suoi elementi dallo scaffale, mai i file.
Fino a 40 raccolte da 500 elementi.

**I file vengono seguiti.** Ogni file è tenuto con un segnalibro (bookmark): se lo rinomini o lo sposti in un'altra cartella
dello stesso disco, lo scaffale lo ritrova (e salva il nuovo posto). Un file cancellato, nel Cestino o su un disco non
collegato resta in elenco, attenuato con un punto di domanda, finché non lo togli; le operazioni lo saltano.

**Selezionare.** Clic su un elemento; ⇧-clic seleziona un intervallo, ⌘-clic aggiunge o toglie, ⌘A seleziona tutto, un
rettangolo trascinato sullo spazio vuoto seleziona ciò che tocca. Dopo un clic nello scaffale la tastiera è sua: le frecce si
muovono (⇧ estende), Spazio apre **Quick Look** (le frecce scorrono gli elementi, Spazio o Esc chiude), A capo apre, ⌫ toglie
dallo scaffale (i file restano), ⌘⌫ sposta i file nel Cestino, ⌘C copia, ⌘V aggiunge ciò che è negli appunti, Esc
deseleziona. Con VoiceOver ogni elemento dice il tipo, se manca o è selezionato, e offre Apri, Quick Look, Azioni, Sposta a
sinistra/destra, Rimuovi.

**Trascinare fuori.** Trascina un elemento: parte tutta la selezione, come file separati (un solo rilascio nel Finder, in Mail,
in una chat…). Come nel Finder decide l'app dove li lasci: su un'altra cartella dello stesso disco il file viene **spostato**
(lo scaffale lo segue), su un altro disco copiato, ⌥ forza la copia. Le immagini incollate nello scaffale escono sempre come
copia. Trascina gli elementi dentro la griglia per **riordinarli**, o sulla linguetta di un'altra raccolta per spostarli lì.
*Togli dopo averli trascinati fuori* (Impostazioni) li fa uscire dallo scaffale una volta lasciati altrove.

**Azioni** (clic destro su un elemento, o il pulsante ⋯; senza selezione valgono per tutta la raccolta): Apri, **Apri con…**
(solo le app che aprono tutti i file scelti, con le loro icone), Mostra nel Finder, Quick Look, **Condividi…** (i servizi di
macOS, AirDrop per primo), Copia, **Copia percorso** (uno per riga), **Copia in… / Sposta in…** (scegli una cartella; i nomi
già presi diventano "nome 2"), **Rinomina…**, **Comprimi (ZIP)**, **Ridimensiona o converti…**, **Riconosci testo**, Crea PDF,
Unisci in verticale / affiancate, Togli dallo scaffale, Sposta nel Cestino. I lavori lunghi mostrano l'avanzamento sotto lo
scaffale con Annulla; i risultati (l'archivio, le nuove immagini, il testo riconosciuto) finiscono nella raccolta.

- **Rinomina** funziona come nel Finder, con anteprima dal vivo: cerca e sostituisci, testo prima/dopo, un numero (inizio,
  cifre, prima o dopo), la data del file, maiuscole/minuscole, o un nome nuovo per tutti (numerato). L'estensione non cambia
  mai. Un nome già preso, ripetuto nel gruppo, vuoto, troppo lungo o con / o : appare in arancione e non si rinomina nulla
  finché non è corretto; nulla viene mai sovrascritto. Per qualche secondo dopo compare **Annulla**.
- **ZIP** usa `ditto` di macOS, come il Finder (fork delle risorse e attributi estesi conservati). Un elemento dà "nome.zip",
  più elementi "Archivio.zip" con gli elementi al primo livello, accanto al primo elemento (o in Download se quella cartella
  non è scrivibile). Nessuna password: la cifratura con password dello ZIP è debole.
- **Immagini**: ridimensiona per larghezza, percentuale o lato maggiore (mai ingrandite), converti in PNG, JPEG, HEIC o TIFF
  (HEIC solo se questo Mac sa codificarlo), qualità per JPEG/HEIC, togli i metadati (posizione, fotocamera, XMP; il profilo
  colore resta), tieni gli originali (nuovi file "foto-1200.jpg") o sostituiscili (gli originali vanno nel Cestino, così si
  possono recuperare). Non c'è una compressione PNG con perdita: per un PNG più leggero convertilo in JPEG o HEIC.
- **Riconosci testo** legge le immagini e le prime 5 pagine dei PDF con Vision di macOS (su questo Mac, nulla viene
  caricato), prima nelle tue lingue; un PDF che contiene già testo dà quel testo. Il risultato va negli appunti e sullo scaffale.

**Altro nel menu delle azioni** (round 6): **AirDrop** invia i file e i link selezionati direttamente ad AirDrop (macOS chiede
il dispositivo) senza passare da Condividi…; **Copia nomi** copia i nomi, uno per riga (di un link, l'indirizzo). Sotto le
operazioni: **Seleziona** (Seleziona tutto, Inverti selezione, o solo Immagini, File e cartelle, Link, Testi o Elementi
mancanti della raccolta), **Ordina per** Nome (i numeri per valore, come nel Finder), Data di aggiunta (prima i più vecchi),
Tipo o Dimensione (prima i più grandi), e **Svuota**: Rimuovi elementi mancanti, o **Rimuovi tutto…** (con una domanda se gli
elementi sono più di uno; i file restano dove sono). L'ordinamento cambia l'ordine della raccolta per sempre (trascina per
riordinare di nuovo).

**Le tue azioni** (Impostazioni → Isola → Scaffale → Le tue azioni) aggiungono voci tue al menu delle azioni: uno **script
shell**, un **comando rapido** (app Comandi Rapidi), un **flusso di lavoro Automator**, un file **AppleScript o JavaScript**,
**Apri con un'app**, **Sposta in una cartella**. Si aggiungono solo lì, da te; mai da un link, un file trascinato o un'altra app.
I file vengono passati come argomenti separati (percorsi assoluti, quindi un nome non può essere letto come opzione), mai
incollati in una riga di shell; Automator li riceve sullo standard input, uno per riga (per lui un nome con un a capo viene
rifiutato). Gli script girano con un ambiente loro, ridotto (un PATH semplice, la tua HOME e lingua, `COCAINE_SHELF_COUNT`),
un tempo massimo (2 minuti di default) e Annulla; l'output può andare negli appunti o sullo scaffale. **La prima volta che uno
script o un comando rapido parte, Cocaine chiede**, e richiede ogni volta che il file dello script cambia (ne ricorda lo
SHA-256). *Prova* lo esegue una volta senza file e mostra cosa ha scritto. Attiva *Istantanea* per un'azione e tieni premuto ⌥
mentre trascini dei file sull'isola: l'azione appare come destinazione e parte sui file lasciati senza aggiungerli.

**Cartelle osservate** (Impostazioni): i nuovi file di una cartella finiscono da soli in una raccolta. Preimpostazioni per
**Istantanee schermo** (segue la posizione scelta in macOS) e **Download**, o qualsiasi cartella. Regole: estensione, tipo
(immagini, video, PDF…), il nome contiene / inizia / finisce con, solo istantanee (il contrassegno che macOS scrive sulle
istantanee, altrimenti i nomi che macOS usa per loro), ognuna invertibile, tutte o almeno una. I file che arrivano insieme
aspettano che la cartella resti ferma per il tempo scelto (0,5–30 s) e arrivano in un solo gruppo; i download in corso
(.crdownload, .download, .part…) e i file che stanno ancora crescendo non vengono mai presi. Contano solo i file comparsi dopo
l'inizio dell'osservazione. Una cartella osservata eliminata o rinominata risulta mancante; Cocaine riprova una volta al minuto
e dopo lo stop (così una cartella che torna, un accesso concesso dopo o una nuova posizione delle istantanee vengono ripresi da
soli). Il file dello scaffale resta sotto 16 MB: oltre, i nuovi elementi vengono rifiutati con un messaggio (rimuovine prima
qualcuno) invece di salvare uno scaffale che non si potrebbe rileggere. Uno scaffale illeggibile all'avvio viene messo da parte,
mai eliminato, e l'isola lo dice. I file creati da un'immagine incollata (PDF, ZIP, copia ridimensionata) restano con lo
scaffale. Se macOS non lascia leggere la cartella a Cocaine (permesso File e cartelle per Scrivania,
Documenti, Download, volumi rimovibili o di rete), la riga lo dice con un pulsante per il pannello giusto di Impostazioni di
Sistema. L'osservazione è attiva mentre l'isola è accesa.

**Altre vie d'ingresso**: il menu Servizi del Finder (**Add to Cocaine Shelf**, anche per testi, link e immagini selezionati
in altre app), `open -a Cocaine file…`, Apri con del Finder (Cocaine compare come visore di qualsiasi cosa, mai come app
predefinita), la riga di comando `cocaine shelf add <file>…`, `cocaine shelf list [--all] [--json]`, `cocaine shelf clear`, e
**Scuoti per aprire** (Impostazioni, spento di default): scuoti il puntatore mentre trascini dei file e l'isola si apre sullo
scaffale. Lo schema di link `cocaine://` non ha comandi per lo scaffale, quindi una pagina web non può mai aggiungere
percorsi o leggere lo scaffale.

**Dimensioni.** Il modulo Scaffale ha tre dimensioni (Impostazioni → Isola → Schermate): S (una riga), M (una fila di
elementi) e L (le linguette delle raccolte, la barra degli strumenti e la griglia).

**Privacy.** Tutto resta sul Mac. Lo scaffale è salvato in `~/Library/Application Support/Cocaine/shelf` (`library.json`,
leggibile solo da te, scritto in modo atomico): percorsi, segnalibri e i testi e i link che ci metti. Le immagini incollate o
trascinate sono tenute nella sua cartella `items` (leggibile solo da te) finché non le togli. Un file dello scaffale
illeggibile viene messo da parte (`library.json.unreadable-<ora>`), mai cancellato. Lo scaffale di prima delle raccolte viene
portato una volta, compresi i file che non ci sono più (mostrati come mancanti).

**Limiti**: la voce dei Servizi compare quando macOS ha registrato l'app (dopo l'installazione in Applicazioni; al peggio dopo
un logout), e il suo nome è in inglese. Quick Look porta Cocaine in primo piano mentre è aperto e poi restituisce la tastiera
all'app in cui eri. Copia in/Sposta in verso Scrivania, Documenti, Download o altri luoghi protetti può far comparire la
richiesta di permesso di macOS la prima volta. La codifica HEIC non c'è su ogni Mac. La precisione del riconoscimento dipende
dall'immagine; la scrittura a mano spesso sfugge. I link cloud (*Condividi link…*) compaiono solo quando un servizio cloud è
configurato (in un Cocaine successivo).
