### Appunti (isola)

La pagina Appunti dell'isola tiene ciò che copi: **testo** (con la sua formattazione, RTF e HTML, tenuta fino a 1 MB),
**immagini** (salvate come PNG, con miniatura) e **file** (come riferimenti a dove si trovano, mai copie; un file spostato o
eliminato viene segnalato e non si può più incollare). Copiare due volte la stessa cosa non crea mai doppioni.

**Incollare.** Un clic seleziona un elemento; **doppio clic o A capo lo incollano nell'app che stavi usando** (Cocaine lo mette
negli appunti, chiude l'isola e invia ⌘V a quell'app). Con ⇧ lo incolla nell'altro modo: senza formattazione, oppure con, se
*Incolla senza formattazione* è attivo. ⌘1…⌘9 incollano i primi nove elementi mostrati (⇧⌘ per l'altra formattazione).
Inviare ⌘V richiede il permesso **Accessibilità** che Cocaine già chiede (Resta attivo, i tasti dell'HUD); senza, l'elemento
viene solo copiato e la pagina dice "Solo copia" con un pulsante *Consenti…*. Cocaine invia ⌘V e nient'altro, solo all'app
che era in primo piano (se nel frattempo è passata in primo piano un'altra app, copia soltanto), e non osserva mai ciò che
digiti.

**Più elementi insieme.** ⌘-clic e ⇧-clic (⇧↑ ⇧↓, ⌘A da tastiera) ne selezionano altri; la barra in basso offre allora
*Incolla tutto* (nell'ordine in cui li hai scelti, uniti dal separatore scelto nelle Impostazioni: a capo, riga vuota, spazio,
virgola, tab o niente; le immagini restano fuori), *Pila*, *Unisci* (un nuovo elemento di testo; gli originali restano),
*Fissa*, *Elimina*. **Pila Incolla**: *Pila* mette in fila gli elementi; ogni pressione di **Incolla il prossimo** (⌃⌥⌘V di
default, una sua scorciatoia globale, attiva solo mentre una pila aspetta) incolla il successivo. Nessun keylogger che osserva
⌘V: è una scorciatoia di Cocaine.

**Dettagli** (Spazio, la ⓘ di una riga, o *Dettagli*): l'elemento in grande. Il testo scorre (a spaziatura fissa per codice e
JSON); un colore (`#rrggbb`, `rgb()`) mostra un campione; un link mostra il suo dominio (nulla viene scaricato: niente titoli o
icone dalla rete); un'immagine si adatta o si mostra a grandezza reale, con **Copia testo** (il testo che contiene, letto su
questo Mac da Vision); i file mostrano nome, dimensione, cartella e icona, con **Quick Look** e Mostra nel Finder. Da lì:
*Incolla*, *Copia*, **Modifica** (⌘E: salva come nuovo elemento o sostituisci; ⌘Z nell'editor, e ⌘Z nell'elenco rimette un
testo sostituito), **Rinomina** (⌘R: un nome mostrato al posto del contenuto), *Incolla come…* (MAIUSCOLO, minuscolo, Iniziali
Maiuscole, togli spazi, unisci righe, ordina, togli righe doppie, formatta o compatta JSON, codifica/decodifica URL e Base64,
togli il tracciamento dai link), *Fissa in…*, *Elimina*. Un testo formattato ha un selettore *Formattato / Semplice* per
quell'incolla. Su macOS 15.1 e successivi con Apple Intelligence l'editor offre gli Strumenti di scrittura.

**Bacheche**: raccolte con nome (Preferiti è la stella); vedi [pinboards.it.md](pinboards.it.md). Le etichette in cima alla pagina
mostrano una bacheca (⌥1…⌥9, ⌘[ ⌘]) o un tipo (testo, immagini, file, link, colori); trascina gli elementi su un'etichetta per
fissarli.

**Cerca** filtra mentre scrivi (maiuscole e accenti indifferenti; testo, nomi, nomi di file e cartelle, dimensione delle
immagini, testo trovato nelle immagini, app di origine) e capisce alcuni filtri: `type:image|text|file|link|color`,
`app:Safari`, `from:device` o `from:mac`, `board:Prompts` (virgolette per gli spazi: `board:"La mia bacheca"`),
`date:today|yesterday|3h|7d|2w`. Anche digitare mentre l'elenco ha la tastiera lo filtra.

**Suggerimenti.** Senza nulla digitato, fino a due elementi segnati ✦ vengono per primi: ciò che hai già incollato nell'app in
primo piano, ciò che vi hai copiato e la bacheca che le hai associato (Impostazioni → Isola → Bacheche → *Suggerito per primo
in*). Cocaine usa solo ciò che già sa; non legge nulla dalle altre app e non serve Registrazione schermo.

**Altri dispositivi.** Una copia che arriva da iPhone, iPad o un altro Mac tramite Appunti universali è indicata come *Un altro
dispositivo* (mai l'app che per caso era in primo piano), ma solo con *Copie da altri dispositivi* attivo, che dalla 2.9 è
**spento di default**: spento, Cocaine non legge nemmeno quella copia, quindi gli Appunti universali funzionano esattamente come
senza Cocaine. Acceso, legge solo il testo semplice, 3 secondi dopo l'arrivo (mai formattazione, immagini o file, ognuno dei quali
sarebbe un altro trasferimento dall'altro dispositivo). Le impostazioni di prima della 2.9 vengono spente una volta
([predefiniti e funzioni di base](defaults-and-basics.it.md)). Elementi da e verso
l'iPhone tramite iCloud Drive o l'iPhone abbinato, e copie degli Appunti universali tenute fuori dalla cronologia salvata:
[sincronizzazione appunti con iPhone](clipboard-sync.it.md).

**Testo nelle immagini.** Spento di default: con *Trova testo nelle immagini* ogni nuova immagine viene letta su questo Mac
(Vision, in background, non in Modalità risparmio energetico) e il suo testo resta con lei per la ricerca, con ciò che sembra
una chiave, un token o un numero di carta mascherato, al massimo 4.000 caratteri. *Copia testo* funziona comunque, su richiesta.

**Annulla.** Eliminare un elemento, una selezione o *Svuota cronologia* si può annullare per qualche secondo (*Annulla* in
basso, o ⌘Z). **Pausa** smette di registrare, per 15 minuti, un'ora, fino a domani o finché riprendi.

**Mai tenuto**: ciò che i gestori di password e altre app segnano come nascosto, temporaneo o generato (indicatori di
nspasteboard.org, l'indicatore di 1Password); qualsiasi cosa copiata mentre un gestore di password è in primo piano; le app che
escludi nelle Impostazioni; e, a meno che lo spegni, testo che sembra un numero di carta o una chiave/token. Puoi aggiungere le
tue espressioni regolari. Sono euristiche: colgono i casi comuni, non ogni segreto. Escludere un'app in seguito toglie dalla
cronologia ciò che ha copiato, tranne quello che hai fissato.

**Solo in memoria di default.** La cronologia vive in memoria e sparisce quando Cocaine si chiude o l'isola si spegne; ciò che
**fissi in una bacheca è sempre salvato** (vedi bacheche). Con **Salva su questo Mac** tutta la cronologia è salvata in
`~/Library/Application Support/Cocaine/clipboard`, cifrata (AES-GCM) con una chiave casuale tenuta nel tuo Portachiavi di login
(solo questo Mac, mai sincronizzata), file leggibili solo da te. Se il Portachiavi non si può usare, nulla viene salvato e la
pagina lo dice. Spegnerlo chiede se eliminare la cronologia salvata (le bacheche restano) o tenerla cifrata per dopo. Nulla
lascia mai il Mac.

**Limiti** (Impostazioni): quanti elementi (25–500), per quanto tempo (da 1 ora a 30 giorni, o senza limite), spazio totale
(10–250 MB) e il singolo elemento più grande (1–25 MB; la formattazione che non ci sta viene tolta, non il testo). Gli
elementi fissati non contano mai.

**Nascondi dalla condivisione schermo** (spento di default) segna la finestra dell'isola come non catturabile mentre mostra gli
appunti. macOS lo rispetta per le istantanee e la maggior parte delle app di registrazione e condivisione; qualche strumento di
cattura potrebbe registrarla comunque, quindi non affidartici per i segreti.

**Riga di comando**: `cocaine clip list|get|put|paste` (Terminale, script, *Esegui script shell* di Comandi Rapidi). Spenta
di default (Impostazioni → Isola → Appunti → *Riga di comando*): *Solo aggiunta* permette `put`; *Completo* anche la lettura
(`list`, `get`) e `paste`. Parla con l'app aperta tramite un socket che esiste solo finché è permesso (0600, in una cartella
privata, solo lo stesso utente, ogni richiesta firmata con una chiave propria dell'installazione e mai accettata due volte).
Non c'è un link `cocaine://` per gli appunti: una pagina web non può mai leggerli né incollarli.

    cocaine clip list [--board NOME] [--limit N] [--json]
    cocaine clip get [N | --id ID] [--board NOME]
    cocaine clip put [--board NOME] [--title TITOLO] [--copy] [TESTO…]     (senza TESTO: lo standard input)
    cocaine clip paste [N | --id ID] [--board NOME] [--plain]

Il filtro dei segreti e i tuoi pattern valgono anche per `put`.

**Tastiera** (con gli appunti aperti dalla tua combinazione, l'isola aperta da ⌃⌥⌘I, o il campo di ricerca attivo; tutti i tasti, il pannello mobile vicino al puntatore e i modi di ricerca: [clipboard-keyboard.it.md](clipboard-keyboard.it.md)): ↑ ↓ si spostano, A capo / ⇧A capo incollano, ⌘1…9
incolla rapido, ⇧↑ ⇧↓ ⌘A selezionano, Spazio (senza testo) o ⌘Y dettagli, ⌥P preferito, ⌘P fissa, ⌥A capo solo copia, ⌘C copia, ⌘E modifica, ⌘R rinomina, Elimina elimina (o corregge ciò che
hai digitato), ⌘Z annulla, ⌥0…9 e ⌘[ ⌘] bacheche, Esc toglie la selezione, esce dai dettagli o chiude. VoiceOver: attivare una
riga la incolla; le sue azioni sono Copia, Dettagli, Seleziona, Fissa in…, Elimina. Il modulo può essere S (gli elementi più
recenti), M (ricerca ed elenco) o L.

**Limiti di questa funzione**: gli appunti vengono controllati poco più di una volta al secondo (non mentre gli schermi o il Mac
dormono); quando l'app che copia non lo dice, l'origine è l'app in primo piano. Alcune app (desktop remoti, giochi, qualche app
Electron) ignorano un ⌘V sintetico: allora premi ⌘V tu. Quick Look apre il pannello di sistema; con l'isola potrebbe non
prendere la tastiera finché non ci clicchi. Con una build firmata ad hoc, macOS chiede di nuovo l'accesso al Portachiavi dopo
ogni aggiornamento; se rifiuti, nulla viene salvato. Eliminare file non garantisce che i byte vengano cancellati da un SSD: ciò
che rende illeggibile una cronologia eliminata è che anche la sua chiave viene eliminata. Gli Appunti universali (di Apple)
richiedono i dispositivi vicini con Handoff attivo; se le copie scritte da Cocaine vengano offerte all'iPhone non è stato
verificato su un dispositivo.

**Se la cronologia salvata non si può leggere** (danneggiata, un'altra chiave o una versione più recente), Cocaine la sposta con
i suoi file in una cartella `unreadable-<ora>` accanto, riparte vuota e non li elimina mai; lo stesso per il file delle bacheche.
Le cronologie salvate più vecchie (2.6 e precedenti, schema 1) vengono lette così come sono e riscritte nel nuovo formato al
salvataggio successivo; i loro preferiti diventano la bacheca Preferiti.
