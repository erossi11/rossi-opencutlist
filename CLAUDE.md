# CLAUDE.md

Este archivo proporciona guía a Claude Code (claude.ai/code) para trabajar con el código de este repositorio.

## Qué es esto

**OpenCutList** es una extensión de SketchUp (un paquete `.rbz`) que genera listas de corte (cutlists), diagramas de corte (1D y 2D), planos de embalaje/anidado (packing/nesting), estimaciones de costo/peso y etiquetas para proyectos de carpintería. La extensión incrusta un `UI::HtmlDialog` basado en Chromium dentro de SketchUp; el frontend del diálogo es jQuery/Bootstrap plano + plantillas precompiladas con Twig, y se comunica con un backend en Ruby que corre dentro de SketchUp a través de un puente de URL personalizado `skp:`. Parte del código de geometría crítico en rendimiento (recorte de polígonos, bin packing, operaciones de imagen raster) está implementado en C++ y se carga en Ruby vía Fiddle.

Intervienen tres lenguajes: **Ruby** (lógica del plugin de SketchUp), **JavaScript** (UI del diálogo) y **C++** (librerías nativas). Un pipeline de build con **gulp** compila LESS, Twig y los YAML de i18n, y empaqueta todo en `dist/ladb_opencutlist.rbz`.

Este fork/rama (`integracion-rossi`) es un punto de partida sobre el que se seguirán agregando **módulos de integración con un sistema de gestión interno** (ver sección dedicada más abajo). El objetivo general de las modificaciones en este repositorio no es tanto extender las funcionalidades "core" de OpenCutList, sino conectarlo con procesos internos externos (presupuestos, producción, etc.).

## Comandos de build

Todo el tooling de build vive en `build/` y usa gulp. Instalar dependencias una vez:

```bash
cd build
npm install
```

Tareas comunes (ejecutar desde `build/`):

```bash
gulp compile          # compila LESS -> CSS, minifica CSS/JS de libs, compila plantillas Twig, compila i18n yaml -> js, compila HTML del diálogo
gulp build             # compile + incrementa versión + crea dist/ladb_opencutlist.rbz  (esta es la tarea `gulp` por defecto)
gulp build --env=dev   # crea un archivo con sabor "-dev" (habilita idiomas de debug extra, locales zz_*, etc.)
```

Ejecutar `gulp compile` después de editar cualquier archivo bajo `src/ladb_opencutlist/less`, `twig`, o `yaml/i18n-src` — SketchUp lee los archivos `css`, `js/templates/*-twig-templates.js`, `js/i18n/*.js` y `html/dialog-*.html` ya compilados, no los fuentes directamente.

### Librerías nativas C++ (Clipper2/Clippy, Packy, Imagy)

Se compilan con CMake (`CMakeLists.txt` en la raíz → `src/ladb_opencutlist/cpp/lib`), invocado a través de wrappers de gulp:

```bash
cd build
gulp c_libs            # prepara (cmake -S .. -B cmake-build) + compila + instala
gulp c_libs_build_install
gulp c_libs_clean
```

En Windows esto requiere CMake, MSVC (Desktop Development with C++), y `LongPathsEnabled=1` en el registro (requiere reinicio) — ver `docs/01-development.md` para la configuración completa. Las librerías compiladas se ubican en `src/ladb_opencutlist/bin/<platform>/` y se cargan de forma diferida (lazy) desde Ruby vía `require_relative 'lib/fiddle/<lib>/<lib>'` (ver `unload_c_lib_command` en `plugin.rb` para la ruta de descarga usada durante la iteración en desarrollo).

### Agregar un idioma

Duplicar `src/ladb_opencutlist/yaml/i18n-src/fr.yml` en un nuevo `<lang>.yml`, definir la clave `_label`, traducir el resto, y luego ejecutar `gulp compile`. No enviar PRs para traducciones nuevas/modificadas — las traducciones se gestionan vía Transifex; tocar estos archivos solo si el usuario lo pide explícitamente.

## Ejecutar/probar en SketchUp (sin necesidad de build)

Para iterar sobre Ruby sin reempaquetar el `.rbz`:

1. Desinstalar cualquier OpenCutList `.rbz` instalado.
2. Instalar "AS On-Demand Ruby / Extension Loader" (o "Extension Sources") desde el Extension Warehouse.
3. Cargar `src/ladb_opencutlist.rb` directamente mediante ese loader.
4. **SketchUp solo carga un archivo Ruby una vez por sesión.** Después de editar un `.rb`, recargar solo ese archivo a través del loader — no esperar que los cambios aparezcan automáticamente. Si se cambian definiciones de método/clase (no solo el cuerpo del método), reiniciar SketchUp.
5. Después de editar fuentes `.less`/`.twig`/`.yml`, ejecutar `gulp compile`, y luego cerrar y volver a abrir el diálogo de OpenCutList (no requiere reiniciar SketchUp).

`tools/debug-sketchup.rb <version>` lanza SketchUp con el depurador remoto de Ruby habilitado en el puerto 7777 (ej. `ruby tools/debug-sketchup.rb 25` para SketchUp 2025).

## Tests

Los tests unitarios de Ruby viven en `test/TC_*.rb` y usan `TestUp::TestCase` (la extensión de SketchUp [TestUp2](https://github.com/SketchUp/testup-2)) — requieren `require 'testup/testcase'` y globals de la API de SketchUp (`Geom`, `ORIGIN`, etc.), por lo que **se ejecutan dentro de SketchUp vía TestUp2, no de forma independiente con `ruby` o un runner de Minitest plano**. El `Gemfile` incluye `sketchup-api-stubs` y `minitest` solo para dar soporte a stubs/tooling del editor, no para ejecutar estas suites fuera de SketchUp.

Los tests actuales cubren clases de utilidades/modelos de lógica pura, desacopladas del modelo de documento de SketchUp: `lib/geometrix` (`TC_Ladb_Lib_Geometrix.rb`), el parser de fórmulas (`TC_Ladb_Parser_FormulaParser.rb`), y utilidades de dimensión/eje (`TC_Ladb_Utils_*.rb`). Al agregar tests para código nuevo de lógica pura, seguir este patrón en lugar de intentar testear unitariamente código dependiente del modelo de SketchUp (clases worker que recorren `Sketchup.active_model`, etc.) fuera de SketchUp.

## Linting

`.rubocop.yml` configura `rubocop-sketchup` (apunta a la API de SketchUp 2024, compatibilidad de sintaxis con Ruby 2.2 — la extensión debe correr en versiones antiguas de Ruby de SketchUp). Instalar con `gem install rubocop-sketchup`, ejecutar `rubocop` desde la raíz del repo. Excluye `build/`, `dist/`, `docs/`, `test/`, `tools/`.

## Arquitectura

### Lado Ruby (`src/ladb_opencutlist/ruby`)

- **`plugin.rb`** — el singleton `Plugin` (`PLUGIN`), creado una vez en `main.rb`. Gestiona la configuración del menú/toolbar de SketchUp, las dos instancias de `UI::HtmlDialog` (`tabs_dialog` para la ventana principal, `modal_dialog` para popups), la carga de strings i18n, la persistencia de app-defaults/presets (global vía `Sketchup.write_default`, por modelo vía diccionarios de atributos de entidad), y el **registro de comandos**: `register_command(name, &block)` / `execute_command(name, params)`. Este es el único punto de despacho por el que pasa cada llamada JS→Ruby.
- **`controller/*_controller.rb`** — un controller por pestaña/dominio (`CutlistController`, `MaterialsController`, `OutlinerController`, `ImporterController`, `SettingsController`), cada uno heredando de `Controller`. `setup_commands` registra entradas `PLUGIN.register_command('<domain>_<action>')`; `setup_event_callbacks` conecta observers de SketchUp/plugin. Los controllers mantienen algo de estado (ej. `CutlistController` cachea el último `Cutlist` generado) pero delegan el trabajo real a workers.
- **`worker/<domain>/*_worker.rb`** — una clase por operación (ej. `CutlistGenerateWorker`, `CutlistCuttingdiagram2dWorker`, `CutlistPackingWorker`). Los workers hacen el recorrido real del modelo de SketchUp / cálculo de geometría y devuelven Hashes planos (serializables a JSON) de vuelta a través del controller hacia JS. Las operaciones costosas (diagramas de corte, packing) se dividen en pares de comandos `_start`/`_advance` para que JS pueda manejar un bucle de progreso en lugar de bloquear el hilo de la UI.
- **`model/*`** — objetos de datos/dominio planos: `cutlist` (Cutlist/Group/Part), `cuttingdiagram`, `packing`, `estimate`, `outliner`, `drawing`, `geom` (Size3d etc.), `formula` (lenguaje de fórmulas para columnas calculadas del cutlist), `labels`, `attributes` (wrappers tipados sobre el almacenamiento en diccionarios de atributos de SketchUp, ej. `MaterialAttributes`, `DefinitionAttributes`).
- **`tool/smart_*_tool.rb`** — implementaciones de `Tool` de SketchUp para las herramientas "Smart" de la toolbar (draw, handle, paint, axes, export, reshape), cada una con una tabla `ACTIONS` que dirige las entradas del submenú construidas en `plugin.rb#setup`.
- **`lib/`** — librerías Ruby puras incluidas/empaquetadas: `geometrix` (primitivas de geometría 2D, tiene tests unitarios), `bin_packing_1d`/`bin_packing_2d`, `kuix` (un pequeño toolkit de UI/overlay basado en GL usado para widgets dentro del viewport), `rubyzip`, `write_xlsx`, `rchardet`, y `fiddle/{clippy,packy,imagy}` — bindings delgados de Fiddle hacia las librerías C++ compiladas (operaciones de polígonos basadas en Clipper2, bin-packing/nesting vía Packy, operaciones de imagen vía Imagy).
- **`helper/`, `utils/`, `manipulator/`, `observer/`, `parser/`, `overlay/`** — código de soporte transversal (ej. `DimensionUtils` para parsear/formatear longitudes con conciencia de unidades, `PathUtils` para serializar rutas de entidades de SketchUp usadas para referenciar partes entre JS/Ruby, observers para el seguimiento de cambios en modelo/selección/materiales).

### Lado JS/diálogo (`src/ladb_opencutlist/js`)

- **`dialog.js`** contiene el puente JS→Ruby: `rubyCallCommand(command, params, callback)` encola una llamada (serializada a JSON, codificada en base64/URI) y navega `window.location.href` a `skp:ladb_opencutlist_command@<payload>`, que SketchUp intercepta vía el `add_action_callback` registrado en `plugin.rb#create_tabs_dialog`/`create_modal_dialog`. La respuesta de Ruby vuelve a través de `rubyCommandCallback(id, encodedResponse)`, invocado por Ruby al llamar `execute_script(...)` sobre el diálogo. Solo un comando está en vuelo a la vez (`commandCallStack` + `commandRunning`); de forma similar, Ruby envía eventos asíncronos a JS vía `PLUGIN.trigger_event(event, params)` → `triggerEvent(...)` en JS.
- **`plugins/tabs/jquery.ladb.tab-<name>.js`** — un plugin de jQuery UI por pestaña del diálogo (cutlist, materials, outliner, importer, settings, about, news, sponsor, forum, tutorials), todos extendiendo `jquery.ladb.abstract-tab.js`. Los nombres de pestaña aquí corresponden a los `tab_name` de los controllers en Ruby y a los directorios de plantillas `twig/tabs/<name>/`.
- **`plugins/modals/`, `plugins/components/`** — diálogos modales (editores de parte/material, visores de diagrama de corte/etiquetas, etc.) y componentes de UI reutilizables (inputs de dimensión, editor de fórmulas, etc.).
- **`templates/*-twig-templates.js`** — generados por `gulp twig_compile` a partir de `twig/{components,core,modals,tabs}/**`; no editar a mano, editar los fuentes `.twig` en su lugar.
- **`i18n/*.js`** — generados por `gulp i18n_compile` a partir de `yaml/i18n-src/*.yml` (la fuente de verdad es `fr.yml`, `en.yml` es el fallback/default; otros locales se autocompletan con valores por defecto para las claves faltantes). `zz_*.yml`/`zz_*.js` son pseudo-locales usados solo en builds de dev para detectar strings sin traducir.
- **`lib/`** — librerías JS incluidas (CodeMirror para los editores de fórmula/Ruby, etc.); las variantes `.min.js` son generadas por `gulp js_minify`.

### Flujo de datos para una funcionalidad típica (ej. generar un diagrama de corte)

1. El plugin de la pestaña JS llama `rubyCallCommand('cutlist_group_cuttingdiagram2d_start', {...settings})`.
2. El handler de comando de `CutlistController` busca el `Cutlist`/`Group` cacheado e instancia `CutlistCuttingdiagram2dWorker`, iniciando el cálculo (posiblemente de larga duración, ej. basado en Packy).
3. Para operaciones largas, JS hace polling vía un comando `_advance` emparejado hasta que el worker reporta finalización; el worker/controller devuelve hashes de progreso/resultado.
4. El hash de resultado fluye de vuelta a JS como JSON, se renderiza vía la plantilla Twig correspondiente + plugin de pestaña, o se dibuja vía `viewer.js`.

### Versionado

Los números de versión/build se **generan automáticamente** mediante `gulp version` (parte de `gulp build`) en `dist/manifest.json`, `src/ladb_opencutlist.rb`, `src/ladb_opencutlist/ruby/constants.rb`, y `src/ladb_opencutlist/js/constants.js` — estos archivos llevan marcadores `## /!\ Auto-generated line, do not edit ##`. No editar a mano los strings de versión/build en estos archivos; en su lugar incrementar el `version` de `build/package.json` y dejar que gulp lo propague. De igual forma, el bloque `ex.description` por idioma en `src/ladb_opencutlist.rb` (entre `## DESCRIPTION_START ##`/`## DESCRIPTION_END ##`) se genera a partir de las claves `_description` del yaml de i18n mediante `gulp i18n_compile` — editar el yaml, no el bloque de Ruby generado.

## Integraciones con el sistema de gestión interno

El propósito principal de las modificaciones sobre este repositorio (rama `integracion-rossi`) es agregar **módulos que conecten OpenCutList con un sistema de gestión externo**, para automatizar procesos internos (presupuestos, producción, seguimiento de materiales, etc.) a partir de los datos que ya calcula el plugin. Ya existe un módulo de referencia que sigue este patrón, en `src/ladb_opencutlist/ruby/controller/cutlist_controller.rb`:

- **Comando de entrada**: `export_rossi_command` (registrado como `cutlist_export_rossi` en `setup_commands`), invocado desde JS igual que cualquier otro comando del cutlist.
- **Captura de datos adicionales del usuario**: `solicitar_datos_presupuesto` usa `UI.inputbox` para pedir datos que no vienen del modelo de SketchUp (número de presupuesto, nombre del amoblamiento).
- **Reutilización de workers existentes**: en vez de reimplementar el cálculo de cortes, el flujo (`calcular_cortes_placas_async` → `procesar_siguiente_grupo_rossi` → `avanzar_optimizacion_rossi`) reutiliza `CutlistCuttingdiagram2dWorker` grupo por grupo, avanzando la optimización con `UI.start_timer` en vez de bloquear el hilo de la UI (mismo patrón `_start`/`_advance` que usan los comandos nativos de cutting-diagram).
- **Armado del payload**: `build_rossi_products` transforma el hash del cutlist (`@cutlist.to_hash`) más los resultados de optimización en la estructura de datos que espera el sistema externo.
- **Envío**: `enviar_post_rossi` hace un `Net::HTTP::Post` (JSON, con header `X-API-KEY`) hacia el endpoint del sistema de gestión, también dentro de un `UI.start_timer` para no bloquear SketchUp.

**Al agregar nuevos módulos de integración, seguir este mismo patrón** (controller → captura de datos si falta algo → reutilizar/orquestar workers existentes vía `UI.start_timer` → construir payload → llamada HTTP asíncrona), y exponerlos como comandos nuevos registrados en `setup_commands` del controller correspondiente, invocables desde un botón/tab en JS vía `rubyCallCommand`.

**Credenciales**: el endpoint y el `X-API-KEY` de `enviar_post_rossi` **no** están hardcodeados en el código fuente (que se empaqueta dentro del `.rbz` distribuible y sería legible por cualquiera que lo descomprima). Se leen vía `PLUGIN.read_default(Plugin::SETTINGS_KEY_ROSSI_API_ENDPOINT, nil)` / `PLUGIN.read_default(Plugin::SETTINGS_KEY_ROSSI_API_KEY, nil)` (constantes definidas en `plugin.rb` junto al resto de `SETTINGS_KEY_*`), y se configuran una vez por instalación desde la Consola de Ruby de SketchUp:

```ruby
PLUGIN.write_default('settings.rossi_api_endpoint', 'https://.../api/opencutlist/importar')
PLUGIN.write_default('settings.rossi_api_key', 'tu-api-key')
```

Si no están configurados, `enviar_post_rossi` muestra un mensaje explicando cómo hacerlo en vez de enviar la petición. **Los módulos nuevos deben seguir el mismo mecanismo** (`read_default`/`write_default` con una constante `SETTINGS_KEY_*` propia) en lugar de escribir URLs/claves como literales en el código fuente.
