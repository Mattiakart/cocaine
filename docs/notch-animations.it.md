# Il notch: movimento, ricarica, gesti, misure, controlli, promemoria

Questa pagina spiega cosa ha preso il round 6 da Boring Notch (TheBoredTeam/boring.notch) e come Cocaine lo adatta alla
propria interfaccia. Tutto usa il sistema di movimento di `Sources/Motion.swift` (docs/motion.it.md) e ha un'alternativa
per Riduci movimento. L'isola si apre ancora nell'istante in cui il puntatore tocca il notch: la molla dà forma
all'apertura, ma non la ritarda mai.

## Cosa fa Boring Notch e cosa ha preso Cocaine

I valori vengono dal sorgente di Boring Notch (`ContentView.swift`, `sizing/matters.swift`, `extensions/PanGesture.swift`,
`BoringBattery.swift`, `BatteryActivityManager.swift`).

- **Apertura e chiusura.** Boring Notch apre con una molla (risposta 0,42, smorzamento 0,8) e chiude con una molla
  critica (0,45 / 1,0), senza rimbalzo. Cocaine ha due nuovi token, `Motion.notchOpen` e `Motion.notchClose`, con gli
  stessi valori. La finestra si restringe dopo 0,56 s, cioè dopo che la molla di chiusura si è fermata.
- **Ombra.** Da aperta, l'isola proietta un'ombra leggera (nero 0,55, raggio 6).
- **Contenuto.** La pagina appare in dissolvenza. Poi ogni modulo sale gli ultimi 8 pt, uno dopo l'altro
  (`ModuleStagger`). Il movimento segue il progresso dell'apertura: se l'isola inverte a metà, i moduli tornano indietro
  da dove sono.
- **Gesti.** Come in Boring Notch, un asse deve prevalere 1,5 volte sull'altro. L'isola segue le dita con la molla
  `follow` (0,38 / 0,8), con una scala da 0,94 a 1,1.
- **Batteria.** Come in Boring Notch, la notifica arriva subito tramite la notifica IOKit e dura 3 s. Il riempimento è
  verde in carica o carica completa, rosso quando è scarica e giallo con Risparmio energetico.
- **Non preso: il ritardo su hover.** Boring Notch aspetta 0,3 s prima di aprire. Cocaine apre e chiude subito su hover,
  come ha deciso l'utente.
- **Non preso: il "sneak peek" ai lati del notch.** L'HUD di Cocaine resta sotto il notch.
- **Controlli.** I comandi musicali appartengono a un'altra area. Cocaine aggiunge invece il modulo **Controlli**,
  configurabile.
- **Promemoria.** Il calendario di Boring Notch li gestisce. Cocaine aggiunge un modulo e uno schermo **Promemoria**
  (EventKit).

Nuovi ruoli di movimento:

- `chargeIn`: il fulmine compare.
- `levelFill`: il riempimento della batteria.
- `stateSwap`: play ↔ pausa, un controllo che si accende, l'elemento a destra del notch, un promemoria spuntato.
- `gestureFollow`: l'isola segue le dita.
- `contentIn`: l'arrivo dei moduli.

Con Riduci movimento questi ruoli cambiano così:

- Ciò che si muove soltanto cambia di colpo: `levelFill` e `gestureFollow`.
- Ciò che arriva usa invece una dissolvenza breve: `chargeIn`, `contentIn` e `stateSwap`.

## Ricarica e batteria

Sotto il notch compare un HUD in questi casi:

- Colleghi il caricatore. Mostra "In carica", con il tempo alla carica completa quando macOS lo conosce, oppure "Collegato" se macOS trattiene la carica.
- Scolleghi il caricatore. Mostra "A batteria", con il tempo rimanente quando è noto.
- La batteria è carica. Lo dice una volta per ogni collegamento.
- La batteria è scarica. Lo dice una volta alla soglia scelta (20 % di default) e un'altra volta al 10 %.
- Cambia la modalità Risparmio energetico.

Il riempimento della batteria corre da vuoto al livello mentre il contenitore scende, e il fulmine cresce insieme a lui.

Le impostazioni sono in Impostazioni → Isola → Notch: **Avvisi di ricarica** e **Avviso batteria scarica** (no, 10, 20 o
30 %).

**Niente indicatore della luminosità sopra (round 7).** Quando colleghi o scolleghi il caricatore, macOS cambia da solo la
luminosità, e nella 2.8.0 quel cambio mostrava l'indicatore della luminosità sopra l'HUD di ricarica. Ora l'indicatore compare
solo per i cambi fatti da te:

- Per 6 s dopo aver collegato o scollegato il caricatore, o dopo il risveglio degli schermi, conta solo un tasto della
  luminosità premuto dopo quel cambio.
- Negli altri momenti un tasto mostra sempre l'indicatore; un salto più grande senza tasto (un cursore in Centro di
  Controllo, Impostazioni di Sistema o nell'isola) lo mostra solo se negli ultimi 2 s hai cliccato, trascinato o scritto.
  La luminosità automatica non lo mostra mai.
- La fonte di alimentazione viene riletta appena la luminosità cambia, così anche il primo passo, che può arrivare prima
  della notifica di IOKit, resta silenzioso. L'oscuramento di Cocaine non mostra mai l'indicatore.

## Gesti

I gesti usano due dita sul trackpad:

- **In su sull'isola aperta** la chiude. L'isola resta chiusa finché il puntatore non lascia il notch.
- **In giù appena sotto il notch chiuso** la apre. Il puntatore sul notch apre già l'isola (al passaggio), quindi il gesto
  parte da una fascia sotto il notch e le sue ali (64 pt in giù, 48 pt ai lati), oppure dal notch subito dopo un gesto in su.
  Nella 2.8.0 doveva partire dal notch, dove l'isola è già aperta: non si poteva mai usare.
- **A sinistra o a destra sull'isola aperta** passa allo schermo successivo o precedente.

L'isola segue le dita, e quando le sollevi torna al suo posto con una molla.

Il gesto viene ignorato in questi casi:

- Se è cominciato sopra qualcosa che scorre da sé, come un elenco lungo o i segmenti del timer.
- Con la rotella del mouse.
- Con l'inerzia dopo che hai sollevato le dita.
- Mentre l'isola tiene aperta una domanda o un modulo della mensola.

L'inizio di ogni gesto (dove, quale isola, aperta o no) viene registrato nel log a livello debug, per la diagnosi.

Gli interruttori e la **Sensibilità** (bassa, media o alta) sono nelle impostazioni del Notch. Il pinch non è usato:
macOS lo manda solo alla finestra sotto il puntatore, e l'isola chiusa lascia passare il puntatore.

## Misure

- **Isola aperta**: Standard (640 × 214), Grande (700 × 244), Molto grande (760 × 274), oppure i cursori Larghezza e Altezza. L'isola non è mai più piccola della misura standard.
- **Il contenuto cresce con lei (round 7).** Ogni modulo conosce il suo riquadro nell'isola standard e cresce da lì: la
  fotocamera occupa tutta l'altezza in più mantenendo le proporzioni (250 × 146 → circa 353 × 206 in Molto grande), la colonna
  stretta di Home, File e Stato si allarga con la pagina, crescono i riquadri e le icone dei media, le istantanee, i controlli
  rotondi, il timer di concentrazione e i cursori dei monitor; gli elenchi mostrano più righe. Il testo resta sulla scala
  tipografica unica. I riquadri dei media non escono più dal loro spazio sotto una barra dei menu alta.
- **Angoli** dell'isola aperta: da 16 a 40 pt.
- **Chiusa, sugli schermi senza notch**: larghezza, altezza (uguale alla barra dei menu o personalizzata) e angoli. **Vale per** sceglie se la misura vale per tutti questi schermi o per uno solo.
- Sugli schermi con il notch, l'isola chiusa ha la misura del notch.

## Controlli

Il modulo **Controlli** è una fila di pulsanti rotondi, tutti della stessa misura. Puoi metterci:

- Cocaine e Resta attivo,
- brano precedente, play/pausa e brano successivo,
- muto,
- il timer di concentrazione,
- Istantanea schermo,
- spegni lo schermo,
- Promemoria e Impostazioni.

In Impostazioni → Isola → Notch → Controlli scegli quali compaiono (fino a 7) e in che ordine. Poi aggiungi il modulo a uno
schermo in Schermi.

## Promemoria

- Lo schermo **Promemoria** è nascosto finché non lo mostri in Schermi. Il modulo può andare anche su qualsiasi altro schermo.
- Il permesso si chiede dall'isola stessa. Se lo hai negato, il pulsante apre Privacy e sicurezza.
- Un clic sul cerchio spunta il promemoria. Resta barrato per 1,4 s, e un secondo clic lo annulla. Poi viene salvato come completato.
- **Aggiunta rapida**: scrivi e premi Invio. Il promemoria va nell'elenco scelto ed è in scadenza oggi se la pagina mostra "Oggi e scaduti".

## Test

- `--notch-test` usa una sorgente finta e non legge mai i tuoi promemoria.
- I render usano dati di esempio: `--render-island … --notch-fixture charging|full|low|unplugged|lowpower|reminders|reminders-ask|controls|sizes|large|xl|max|mod-<modulo>-<s|m|l>`.
- `--island-review-test` (round 7): la regola della luminosità con l'HUD di ricarica, la zona del gesto e sequenze sintetiche
  di gesti, la crescita del contenuto, e un controllo che disegna ogni modulo in ogni misura e misura ciò che esce dal riquadro.

## Non verificato dal vivo

- La callback IOKit con un collegamento reale.
- I gesti su un trackpad reale (verificati con sequenze sintetiche).
- La luminosità che macOS imposta a un collegamento reale (verificata con orologio, input e alimentazione finti).
- EventKit Promemoria.
- I permessi nel livello Developer ID.

Tutte queste cose sono costruite e testate solo con sorgenti finte.
