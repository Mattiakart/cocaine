### Gli appunti dalla tastiera

Tutto quello che fanno gli [appunti](clipboard.it.md) si può fare senza mouse, da qualsiasi app, come in
[Maccy](https://github.com/p0deje/Maccy).

**Aprirli.** **⌃⌘V** (Impostazioni → Isola → Appunti → *Apri gli appunti*; qualsiasi combinazione registrata lì, o nessuna)
apre gli appunti con la tastiera già dentro. Premuto di nuovo, o Esc, li chiude. *Si apre* sceglie dove:

- **Isola** (predefinito): la pagina Appunti dell'isola, aperta dal notch.
- **Puntatore**: un pannello mobile di Cocaine con l'angolo in alto a sinistra sul puntatore.
- **Centro**: lo stesso pannello al centro dello schermo dove si trova il puntatore.
- **Ultimo posto**: dove l'hai trascinato l'ultima volta (trascinalo dallo sfondo); su uno schermo che non c'è più, al centro.

Il pannello mobile è disegnato da Cocaine, nero come l'isola, con le sue domande (Fissa in…, Rinomina, Cancella) al suo
interno; non è un pop-up di sistema. Non rende mai Cocaine l'app attiva, quindi l'app in cui stavi scrivendo resta quella in
cui si incolla. Se nessuno schermo dell'isola contiene il modulo Appunti, la scorciatoia apre il pannello sotto il bordo alto
dello schermo. Ogni apertura riparte da zero: nessuna ricerca, nulla selezionato, l'elemento più recente evidenziato.

**Tasti** (nell'isola e nel pannello):

| Tasti | Cosa fanno |
|---|---|
| scrivi | cerca subito (il campo di ricerca del pannello ha la tastiera; nell'isola scrivere lo riempie) |
| ↑ ↓, Inizio Fine, ⌘↑ ⌘↓, Pagina su/giù | spostano l'evidenziazione |
| A capo | incolla nell'app in cui eri |
| ⇧A capo | incolla con l'altra formattazione (senza, o con quando *Incolla senza formattazione* è attivo) |
| ⌥A capo, ⌥⇧A capo | l'altro modo: solo copia (quando A capo incolla), o incolla (quando A capo copia soltanto) |
| ⌘1 … ⌘9, ⇧⌘1 … ⇧⌘9 | incollano le prime nove righe (le righe mostrano ⌘1…⌘9 quando aperti dalla tastiera) |
| ⌘Y, Spazio (senza testo) | dettagli dell'elemento (di nuovo, o Esc: indietro) |
| ⌥P | aggiunge o toglie dai Preferiti |
| ⌘P | Fissa in… una bacheca |
| ⌥⌫ (anche mentre scrivi), ⌘⌫, Elimina (senza testo) | elimina l'elemento (o la selezione); ⌘Z annulla |
| ⌥⌘⌫ | cancella: solo la cronologia, o tutto (con domanda) |
| ⌘C, ⌘E, ⌘R | copia, modifica, rinomina |
| ⇧↑ ⇧↓, ⌘A | selezionano più elementi (A capo li incolla insieme) |
| ⌥0 … ⌥9, ⌘[ ⌘] | bacheche |
| Esc | cancella la ricerca, poi la selezione, poi chiude |

I tasti lettera (P, Y) si riconoscono dalla lettera che scrivono, quindi restano sulla loro lettera con AZERTY, Dvorak e
altri layout. Mentre un metodo di input compone (giapponese, cinese, coreano…) ogni tasto è suo: ↑ ↓ scelgono un candidato,
Invio conferma, Esc annulla la composizione; i tasti dell'elenco tornano a funzionare quando il testo è confermato.

**Ricerca** (*Cerca* nelle impostazioni):

- **Parole** (predefinita): ogni parola, ovunque, maiuscole e accenti indifferenti; i filtri `type:`, `app:`, `board:`,
  `from:`, `date:` funzionano sempre.
- **Approssimata**: le lettere in ordine, anche non vicine (`gpom` trova "git push origin main"); prima le migliori.
- **Regex**: un'espressione regolare, maiuscole indifferenti (una non valida non trova nulla; al massimo 300 caratteri; si
  cercano i primi 100.000 caratteri di ogni elemento).
- **Mista**: prima parole intere; se non trova nulla, un'espressione regolare; se ancora nulla, approssimata.

**Ordine** (*Ordine*): *Recenti* (predefinito), *Più incollati* (quante volte l'hai incollato, in qualsiasi app), o *A–Z* per
nome o testo.

**Incollare nell'altra app** richiede il permesso **Accessibilità** (Cocaine invia ⌘V e nient'altro, solo all'app che era in
primo piano). Senza, A capo copia soltanto, e in fondo agli appunti compare *Solo copia: per incollare serve Accessibilità*
con un pulsante *Consenti…* che lo chiede a macOS (o apre Privacy e sicurezza → Accessibilità). Nulla viene incollato a tua
insaputa: se un'altra app passa in primo piano prima di ⌘V, l'elemento viene solo copiato.

**VoiceOver.** All'apertura dice quanti elementi ci sono e i tasti; spostando l'evidenziazione legge l'elemento; le azioni di
ogni riga sono Copia, Incolla con/senza formattazione (testo formattato), Dettagli, Seleziona, Fissa in…, Invia a iPhone,
Elimina, e il suo valore dice "Comando N lo incolla" per le prime nove. Il pannello è una finestra mobile chiamata *Appunti*.

**Limiti.** Le scorciatoie globali possono essere già prese da un'altra app: il pulsante della scorciatoia diventa arancione
(*Usata da un'altra app*). Il pannello mobile si chiude quando un'altra app prende la tastiera (⌘Tab) o fai clic altrove;
Quick Look dai dettagli prende la tastiera, quindi il pannello si chiude. Alcune app ignorano un ⌘V sintetico (desktop remoti,
giochi): premi ⌘V tu. L'incolla in un'altra app, la posizione del pannello e VoiceOver sono stati verificati con i test
(`--keyboard-test`) e i render, non inviando tasti veri ad altre app in un test.
