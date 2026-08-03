module Ladb::OpenCutList

  require_relative 'controller'
  require_relative '../model/attributes/material_attributes'
  require_relative '../model/attributes/definition_attributes'
  require_relative '../observer/app_observer'
  require_relative '../observer/selection_observer'
  require_relative '../observer/materials_observer'
  require_relative '../observer/model_observer'
  require_relative '../lib/fiddle/packy/packy'
  require 'json'
  require 'net/http'
  require 'uri'

  Packy = Fiddle::Packy

  class CutlistController < Controller

    def initialize()
      super('cutlist')
    end

    def setup_commands

      # Setup opencutlist dialog actions
      PLUGIN.register_command("cutlist_generate") do |settings|
        generate_command(settings)
      end

      PLUGIN.register_command("cutlist_export_rossi") do
        export_rossi_command
      end

      PLUGIN.register_command("cutlist_export") do |settings|
        export_command(settings)
      end

      PLUGIN.register_command("cutlist_estimate_start") do |settings|
        estimate_start_command(settings)
      end

      PLUGIN.register_command("cutlist_estimate_advance") do |settings|
        estimate_advance_command
      end

      PLUGIN.register_command("cutlist_estimate_next") do |settings|
        estimate_next_command
      end

      PLUGIN.register_command("cutlist_estimate_cancel") do |settings|
        estimate_cancel_command
      end

      PLUGIN.register_command("cutlist_numbers_save") do |settings|
        numbers_command(settings, false)
      end

      PLUGIN.register_command("cutlist_numbers_reset") do |settings|
        numbers_command(settings, true)
      end

      PLUGIN.register_command("cutlist_highlight_parts") do |settings|
        highlight_parts_command(settings)
      end

      PLUGIN.register_command("cutlist_layout_parts") do |settings|
        layout_parts_command(settings)
      end

      PLUGIN.register_command("cutlist_layout_to_layout") do |settings|
        layout_to_layout_command(settings)
      end

      PLUGIN.register_command("cutlist_part_get_thumbnail") do |part_data|
        part_get_thumbnail_command(part_data)
      end

      PLUGIN.register_command("cutlist_part_update") do |settings|
        part_update_command(settings)
      end

      PLUGIN.register_command("cutlist_write_parts") do |settings|
        write_parts_command(settings)
      end

      PLUGIN.register_command("cutlist_group_cuttingdiagram1d_start") do |settings|
        group_cuttingdiagram1d_start_command(settings)
      end

      PLUGIN.register_command("cutlist_group_cuttingdiagram1d_advance") do
        group_cuttingdiagram1d_advance_command
      end

      PLUGIN.register_command("cutlist_cuttingdiagram1d_write") do |settings|
        cuttingdiagram1d_write_command(settings)
      end

      PLUGIN.register_command("cutlist_group_cuttingdiagram2d_start") do |settings|
        group_cuttingdiagram2d_start_command(settings)
      end

      PLUGIN.register_command("cutlist_group_cuttingdiagram2d_advance") do
        group_cuttingdiagram2d_advance_command
      end

      PLUGIN.register_command("cutlist_cuttingdiagram2d_write") do |settings|
        cuttingdiagram2d_write_command(settings)
      end

      PLUGIN.register_command("cutlist_labels") do |settings|
        labels_command(settings)
      end

      PLUGIN.register_command("cutlist_reset_prices") do
        reset_prices_command
      end


      PLUGIN.register_command("cutlist_group_packing_start") do |settings|
        group_packing_start_command(settings)
      end

      PLUGIN.register_command("cutlist_group_packing_advance") do
        group_packing_advance_command
      end

      PLUGIN.register_command("cutlist_group_packing_cancel") do
        group_packing_cancel_command
      end

      PLUGIN.register_command("cutlist_packing_write") do |settings|
        packing_write_command(settings)
      end

    end

    def setup_event_callbacks

      PLUGIN.add_event_callback([
                                   AppObserver::ON_NEW_MODEL,
                                   AppObserver::ON_OPEN_MODEL,
                                   AppObserver::ON_ACTIVATE_MODEL,
                                   SelectionObserver::ON_SELECTION_BULK_CHANGE,
                                   SelectionObserver::ON_SELECTION_CLEARED,
                                   MaterialsObserver::ON_MATERIAL_CHANGE,
                                   MaterialsObserver::ON_MATERIAL_REMOVE,
                                   ModelObserver::ON_DRAWING_CHANGE,
                               ]) do |params|

        # Invalidate Cutlist if it exists
        @cutlist.invalidate if @cutlist

      end

      PLUGIN.add_event_callback([
                                  AppObserver::ON_QUIT,
                                  'on_tabs_dialog_close',
                                  'on_tabs_dialog_minimized'
                                ]) do |params|

        # Cancel all Packy runs
        Packy.optimize_cancel_all

      end
    end

    private

    # -- Commands --


    def export_rossi_command
      unless @cutlist
        UI.messagebox('Primero debe generar el listado de partes.')

        return {
          ok: false,
          error: 'cutlist_not_generated'
        }
      end

      datos_presupuesto = solicitar_datos_presupuesto

      return {
        ok: false,
        cancelled: true
      } unless datos_presupuesto

      cutlist_hash = @cutlist.to_hash

      calcular_cortes_placas_async(
        cutlist_hash,
        datos_presupuesto
      )

      {
        ok: true,
        processing: true
      }
    end

    def calcular_cortes_placas_async(
      cutlist_hash,
      datos_presupuesto
    )
      require_relative '../worker/cutlist/cutlist_cuttingdiagram2d_worker'

      groups = cutlist_hash[:groups] || cutlist_hash['groups'] || []

      grupos_placa = groups.select do |group_hash|
        material_type = (
          group_hash[:material_type_strippedname] ||
          group_hash['material_type_strippedname'] ||
          ''
        ).to_s.strip

        material_type == 'sheet_good'
      end

      cortes_por_grupo = {}

      procesar_siguiente_grupo_rossi(
        grupos_placa,
        0,
        cutlist_hash,
        datos_presupuesto,
        cortes_por_grupo
      )
    end

    def procesar_siguiente_grupo_rossi(
      grupos,
      indice,
      cutlist_hash,
      datos_presupuesto,
      cortes_por_grupo
    )
      if indice >= grupos.length
        finalizar_exportacion_rossi(
          cutlist_hash,
          datos_presupuesto,
          cortes_por_grupo
        )

        return
      end

      group_hash = grupos[indice]

      group_id =
        group_hash[:id] ||
        group_hash['id']

      material_name = (
        group_hash[:material_name] ||
        group_hash['material_name'] ||
        'Material sin nombre'
      ).to_s

      # Tamaño estándar de placa utilizado por Rossi.
      std_sheet = '2750mm x 1830mm'

      if group_id.nil?
        puts "ROSSI: grupo sin ID para #{material_name}"

        procesar_siguiente_grupo_rossi(
          grupos,
          indice + 1,
          cutlist_hash,
          datos_presupuesto,
          cortes_por_grupo
        )

        return
      end

      puts "ROSSI: optimizando #{material_name}"
      puts "ROSSI: group_id = #{group_id.inspect}"
      puts "ROSSI: std_sheet = #{std_sheet.inspect}"

      begin
        worker = CutlistCuttingdiagram2dWorker.new(
          @cutlist,
          group_id: group_id,
          std_sheet: std_sheet,
          scrap_sheet_sizes: '',
          saw_kerf: '3mm',
          trimming: '10mm',
          sheet_folding: false
        )

        avanzar_optimizacion_rossi(
          worker,
          grupos,
          indice,
          cutlist_hash,
          datos_presupuesto,
          cortes_por_grupo,
          group_id,
          material_name
        )
      rescue StandardError => e
        puts "ROSSI: error creando el optimizador para #{material_name}"
        puts "#{e.class}: #{e.message}"
        puts e.backtrace.first(10).join("\n")

        UI.messagebox(
          "Error al crear la optimización para " \
          "'#{material_name}'.\n\n" \
          "#{e.class}: #{e.message}"
        )

        cortes_por_grupo[group_id.to_s] = {
          cantidad_cortes: 0,
          cantidad_placas: 0
        }

        procesar_siguiente_grupo_rossi(
          grupos,
          indice + 1,
          cutlist_hash,
          datos_presupuesto,
          cortes_por_grupo
        )
      end
    end

    def avanzar_optimizacion_rossi(
      worker,
      grupos,
      indice,
      cutlist_hash,
      datos_presupuesto,
      cortes_por_grupo,
      group_id,
      material_name
    )
      UI.start_timer(0.05, false) do
        begin
          resultado = worker.run(true)

          puts "ROSSI: resultado worker = #{resultado.class}"
          puts "ROSSI: resultado = #{resultado.inspect}"

          # La primera llamada puede devolver:
          # { estimated_steps: 1 }
          #
          # Todavía no es el diagrama final.
          if resultado.is_a?(Hash)
            puts 'ROSSI: optimizador inicializado, avanzando...'

            avanzar_optimizacion_rossi(
              worker,
              grupos,
              indice,
              cutlist_hash,
              datos_presupuesto,
              cortes_por_grupo,
              group_id,
              material_name
            )

            next
          end

          unless resultado.respond_to?(:sheets)
            raise(
              "El optimizador devolvió un resultado inesperado: " \
              "#{resultado.class}"
            )
          end

          # Si ya existen hojas, la optimización terminó.
          if resultado.sheets.length > 0
            puts "ROSSI: optimización terminada para #{material_name}"
            puts "ROSSI: hojas generadas = #{resultado.sheets.length}"

            procesar_resultado_cortes_rossi(
              resultado,
              cortes_por_grupo,
              group_id
            )

            procesar_siguiente_grupo_rossi(
              grupos,
              indice + 1,
              cutlist_hash,
              datos_presupuesto,
              cortes_por_grupo
            )
          else
            puts 'ROSSI: optimización todavía en proceso...'

            avanzar_optimizacion_rossi(
              worker,
              grupos,
              indice,
              cutlist_hash,
              datos_presupuesto,
              cortes_por_grupo,
              group_id,
              material_name
            )
          end

        rescue StandardError => e
          puts "ROSSI: error optimizando #{material_name}"
          puts "#{e.class}: #{e.message}"
          puts e.backtrace.first(10).join("\n")

          cortes_por_grupo[group_id.to_s] = {
            cantidad_cortes: 0,
            cantidad_placas: 0
          }

          procesar_siguiente_grupo_rossi(
            grupos,
            indice + 1,
            cutlist_hash,
            datos_presupuesto,
            cortes_por_grupo
          )
        end
      end
    end

    def procesar_resultado_cortes_rossi(
      cuttingdiagram,
      cortes_por_grupo,
      group_id
    )
      cuttingdiagram_hash = cuttingdiagram.to_hash

      puts 'ROSSI: diagrama final'
      puts JSON.pretty_generate(cuttingdiagram_hash)

      summary =
        cuttingdiagram_hash[:summary] ||
        cuttingdiagram_hash['summary'] ||
        {}

      total_cut_count = (
        summary[:total_cut_count] ||
        summary['total_cut_count'] ||
        0
      ).to_i

      total_used_count = (
        summary[:total_used_count] ||
        summary['total_used_count'] ||
        0
      ).to_i

      cortes_por_grupo[group_id.to_s] = {
        cantidad_cortes: total_cut_count,
        cantidad_placas: total_used_count
      }

      puts "ROSSI: cortes encontrados = #{total_cut_count}"
      puts "ROSSI: placas utilizadas = #{total_used_count}"
    end

    def finalizar_exportacion_rossi(
      cutlist_hash,
      datos_presupuesto,
      cortes_por_grupo
    )
      rossi_payload = {
        schema_version: '1.0',
        source: 'opencutlist',
        numero_presupuesto:
          datos_presupuesto[:numero_presupuesto],
        nombre_amoblamiento:
          datos_presupuesto[:nombre_amoblamiento],
        filename:
          cutlist_hash[:filename] ||
          cutlist_hash['filename'],
        productos: build_rossi_products(
          cutlist_hash,
          cortes_por_grupo
        )
      }

      puts 'ROSSI: payload final'
      puts JSON.pretty_generate(rossi_payload)

      enviar_post_rossi(rossi_payload)
    end

    def calcular_cortes_placas(cutlist_hash)
      require_relative '../worker/cutlist/cutlist_cuttingdiagram2d_worker'

      groups = cutlist_hash[:groups] || cutlist_hash['groups'] || []
      cortes_por_grupo = {}

      groups.each do |group_hash|
        material_type = (
          group_hash[:material_type_strippedname] ||
          group_hash['material_type_strippedname'] ||
          ''
        ).to_s.strip

        next unless material_type == 'sheet_good'

        group_id =
          group_hash[:id] ||
          group_hash['id']

        next if group_id.nil?


        

        # Tamaño de placa Rossi: 2,75 m × 1,83 m
        std_sheet = '2750mm x 1830mm'

        material_name =
          group_hash[:material_name] ||
          group_hash['material_name'] ||
          'Material sin nombre'

        

        begin
          puts "ROSSI: creando optimizador para #{material_name}"
          puts "ROSSI: group_id = #{group_id.inspect}"
          puts "ROSSI: std_sheet = #{std_sheet.inspect}"

          worker = CutlistCuttingdiagram2dWorker.new(
            @cutlist,
            group_id: group_id,
            std_sheet: std_sheet,
            scrap_sheet_sizes: '',
            saw_kerf: '3mm',
            trimming: '10mm',
            sheet_folding: false
          )

          puts 'ROSSI: ejecutando worker.run(false)'

          cuttingdiagram = worker.run(false)

          puts 'ROSSI: optimización terminada'

          cuttingdiagram_hash = cuttingdiagram.to_hash

          puts JSON.pretty_generate(cuttingdiagram_hash)

          summary =
            cuttingdiagram_hash[:summary] ||
            cuttingdiagram_hash['summary'] ||
            {}

          total_cut_count = (
            summary[:total_cut_count] ||
            summary['total_cut_count'] ||
            0
          ).to_i

          total_used_count = (
            summary[:total_used_count] ||
            summary['total_used_count'] ||
            0
          ).to_i

          cortes_por_grupo[group_id.to_s] = {
            cantidad_cortes: total_cut_count,
            cantidad_placas: total_used_count
          }

        rescue StandardError => e
          mensaje = [
            'Error al calcular cortes de placa.',
            '',
            "Material: #{material_name}",
            "Grupo: #{group_id.inspect}",
            "Placa: #{std_sheet.inspect}",
            '',
            "#{e.class}: #{e.message}",
            '',
            e.backtrace.first(10).join("\n")
          ].join("\n")

          puts mensaje
          UI.messagebox(mensaje)

          # Para que la exportación continúe aunque falle el optimizador
          cortes_por_grupo[group_id.to_s] = {
            cantidad_cortes: 0,
            cantidad_placas: 0
          }
        end
      end

      cortes_por_grupo
    end

    def generate_command(settings)
      require_relative '../worker/cutlist/cutlist_generate_worker'

      @cutlist.invalidate if @cutlist

      worker = CutlistGenerateWorker.new(**settings)

      @cutlist = worker.run

      @cutlist.to_hash
    end

    def solicitar_datos_presupuesto
      prompts = [
        'Número de presupuesto',
        'Nombre del amoblamiento'
      ]

      defaults = [
        '',
        Sketchup.active_model.title.to_s
      ]

      result = UI.inputbox(
        prompts,
        defaults,
        'Datos del presupuesto Rossi'
      )

      # El usuario presionó Cancelar
      return nil unless result

      numero_presupuesto = result[0].to_s.strip
      nombre_amoblamiento = result[1].to_s.strip

      if numero_presupuesto.empty?
        UI.messagebox('Debe ingresar el número de presupuesto.')
        return nil
      end

      if nombre_amoblamiento.empty?
        UI.messagebox('Debe ingresar el nombre del amoblamiento.')
        return nil
      end

      {
        numero_presupuesto: numero_presupuesto,
        nombre_amoblamiento: nombre_amoblamiento
      }
    end


    def build_rossi_products(cutlist_hash, cortes_por_grupo = {})
      groups = cutlist_hash[:groups] || cutlist_hash['groups'] || []

      groups.map do |group|
        group_id =
          group[:id] ||
          group['id']

        material_name =
          group[:material_name] ||
          group['material_name'] ||
          ''

        material_type = (
          group[:material_type_strippedname] ||
          group['material_type_strippedname'] ||
          ''
        ).to_s.strip

        producto = {
          nombre_ocl: material_name.to_s.strip,
          tipo: material_type
        }

        case material_type
        when 'sheet_good'
          espesor = parse_ocl_number(
            group[:std_thickness] ||
            group['std_thickness']
          )

          if espesor <= 0
            raise(
              "No se pudo obtener el espesor del material " \
              "'#{material_name}'."
            )
          end

          producto[:cantidad] = parse_ocl_number(
            group[:total_cutting_area] ||
            group['total_cutting_area']
          )

          producto[:unidad] = 'm2'
          producto[:espesor_ocl] = espesor.round(2)

          producto[:cantidad_piezas] = (
            group[:part_count] ||
            group['part_count'] ||
            0
          ).to_i

          optimizacion =
            cortes_por_grupo[group_id.to_s] ||
            {}

          producto[:cantidad_cortes] = (
            optimizacion[:cantidad_cortes] ||
            0
          ).to_i

          producto[:cantidad_placas] = (
            optimizacion[:cantidad_placas] ||
            0
          ).to_i

        when 'edge'
          producto[:cantidad] = parse_ocl_number(
            group[:total_cutting_length] ||
            group['total_cutting_length']
          )

          producto[:unidad] = 'm'

        else
          producto[:cantidad] = (
            group[:part_count] ||
            group['part_count'] ||
            0
          ).to_i

          producto[:unidad] = 'unidad'
        end

        producto
      end
    end

    def enviar_post_rossi(payload)
      endpoint = PLUGIN.read_default(Plugin::SETTINGS_KEY_ROSSI_API_ENDPOINT, nil)
      api_key = PLUGIN.read_default(Plugin::SETTINGS_KEY_ROSSI_API_KEY, nil)

      if endpoint.to_s.strip.empty? || api_key.to_s.strip.empty?
        UI.messagebox(
          "No se configuró la conexión con el sistema de gestión Rossi.\n\n" \
          "Configurar una vez desde la Consola de Ruby de SketchUp (Ventana > Consola de Ruby):\n\n" \
          "PLUGIN.write_default('#{Plugin::SETTINGS_KEY_ROSSI_API_ENDPOINT}', 'https://.../api/opencutlist/importar')\n" \
          "PLUGIN.write_default('#{Plugin::SETTINGS_KEY_ROSSI_API_KEY}', 'tu-api-key')"
        )
        return
      end

      Sketchup.status_text = 'ROSSI: sincronizando presupuesto...'

      UI.start_timer(0.1, false) do
        begin
          uri = URI.parse(endpoint)

          http = Net::HTTP.new(uri.host, uri.port)
          http.use_ssl = uri.scheme == 'https'
          http.open_timeout = 10
          http.read_timeout = 30

          request = Net::HTTP::Post.new(uri.request_uri)
          request['Content-Type'] = 'application/json'
          request['Accept'] = 'application/json'
          request['X-API-KEY'] = api_key
          request.body = JSON.generate(payload)

          response = http.request(request)
          codigo = response.code.to_i

          if codigo.between?(200, 299)
            respuesta = JSON.parse(response.body)

            Sketchup.status_text = 'ROSSI: sincronización completada'

            UI.messagebox(
              "Envío realizado correctamente.\n\n" \
              "#{respuesta['mensaje']}\n" \
              "Productos recibidos: #{respuesta['cantidad_productos']}"
            )
          else
            Sketchup.status_text = 'ROSSI: el servidor rechazó el envío'

            UI.messagebox(
              "El servidor rechazó el envío.\n\n" \
              "Código HTTP: #{response.code}\n\n" \
              "#{response.body}"
            )
          end

        rescue StandardError => e
          Sketchup.status_text = 'ROSSI: error de sincronización'

          UI.messagebox(
            "Error al enviar el POST.\n\n" \
            "#{e.class}: #{e.message}"
          )
        ensure
          UI.start_timer(3, false) do
            Sketchup.status_text = ''
          end
        end
      end

      nil
    end

    

    def parse_ocl_number(value)
      return 0.0 if value.nil?

      number = value.to_s.gsub(/[^\d,.\-]/, '')

      # OCL en español devuelve, por ejemplo: "1,58 m²"
      if number.include?(',') && number.include?('.')
        # Formato posible: 1.234,56
        number = number.delete('.').tr(',', '.')
      elsif number.include?(',')
        number = number.tr(',', '.')
      end

      number.to_f
    end

    def export_command(settings)
      require_relative '../worker/cutlist/cutlist_export_worker'

      # Setup worker
      worker = CutlistExportWorker.new(@cutlist, **settings)

      # Run !
      worker.run
    end

    def estimate_start_command(settings)
      require_relative '../worker/cutlist/cutlist_estimate_worker'

      # Setup worker
      @estimate_worker = CutlistEstimateWorker.new(@cutlist, **settings)

      # Run !
      @estimate_worker.run
    end

    def estimate_advance_command
      return { :errors => [ 'default.error' ] } unless @estimate_worker

      # Run !
      @estimate_worker.run(:advance)
    end

    def estimate_next_command
      return { :errors => [ 'default.error' ] } unless @estimate_worker

      # Run !
      @estimate_worker.run(:next)
    end

    def estimate_cancel_command
      return { :errors => [ 'default.error' ] } unless @estimate_worker

      # Run !
      @estimate_worker.run(:cancel)
    end

    def numbers_command(settings, reset)
      require_relative '../worker/cutlist/cutlist_numbers_worker'

      # Setup worker
      worker = CutlistNumbersWorker.new(@cutlist, **(settings.merge({ :reset => reset })))

      # Run !
      worker.run
    end

    def highlight_parts_command(settings)
      require_relative '../worker/cutlist/cutlist_highlight_parts_worker'

      # Setup worker
      worker = CutlistHighlightPartsWorker.new(@cutlist, **settings)

      # Run !
      worker.run
    end

    def layout_parts_command(settings)
      require_relative '../worker/cutlist/cutlist_layout_parts_worker'

      # Setup worker
      worker = CutlistLayoutPartsWorker.new(@cutlist, **settings)

      # Run !
      worker.run
    end

    def layout_to_layout_command(settings)
      require_relative '../worker/cutlist/cutlist_layout_to_layout_worker'

      # Setup worker
      worker = CutlistLayoutToLayoutWorker.new(@cutlist, **settings)

      # Run !
      worker.run
    end

    def part_get_thumbnail_command(part_data)
      require_relative '../worker/cutlist/cutlist_get_thumbnail_worker'

      # Setup worker
      worker = CutlistGetThumbnailWorker.new(@cutlist, **part_data)

      # Run !
      worker.run
    end

    def part_update_command(settings)
      require_relative '../worker/cutlist/cutlist_part_update_worker'

      # Setup worker
      worker = CutlistPartUpdateWorker.new(@cutlist, **settings)

      # Run !
      worker.run
    end

    def write_parts_command(settings)
      require_relative '../worker/cutlist/cutlist_write_parts_worker'

      # Setup worker
      worker = CutlistWritePartsWorker.new(@cutlist, **settings)

      # Run !
      worker.run
    end

    def group_cuttingdiagram1d_start_command(settings)
      require_relative '../worker/cutlist/cutlist_cuttingdiagram1d_worker'

      # Setup worker
      @cuttingdiagram1d_worker = CutlistCuttingdiagram1dWorker.new(@cutlist, **settings)

      # Run !
      cuttingdiagram1d = @cuttingdiagram1d_worker.run(true)

      cuttingdiagram1d.to_hash
    end

    def group_cuttingdiagram1d_advance_command
      return { :errors => [ 'default.error' ] } unless @cuttingdiagram1d_worker

      # Run !
      cuttingdiagram1d = @cuttingdiagram1d_worker.run(true)

      if cuttingdiagram1d.bars.length > 0
        @cuttingdiagram1d_worker = nil
        @cuttingdiagram1d = cuttingdiagram1d
      end

      cuttingdiagram1d.to_hash
    end

    def cuttingdiagram1d_write_command(settings)
      require_relative '../worker/cutlist/cutlist_cuttingdiagram1d_write_worker'

      # Setup worker
      worker = CutlistCuttingdiagram1dWriteWorker.new(@cutlist, @cuttingdiagram1d, **settings)

      # Run !
      worker.run
    end

    def group_cuttingdiagram2d_start_command(settings)
      require_relative '../worker/cutlist/cutlist_cuttingdiagram2d_worker'

      # Setup worker
      @cuttingdiagram2d_worker = CutlistCuttingdiagram2dWorker.new(@cutlist, **settings)

      # Run !
      cuttingdiagram2d = @cuttingdiagram2d_worker.run(true)

      cuttingdiagram2d.to_hash
    end

    def group_cuttingdiagram2d_advance_command
      return { :errors => [ 'default.error' ] } unless @cuttingdiagram2d_worker

      # Run !
      cuttingdiagram2d = @cuttingdiagram2d_worker.run(true)

      if cuttingdiagram2d.sheets.length > 0
        @cuttingdiagram2d_worker = nil
        @cuttingdiagram2d = cuttingdiagram2d
      end

      cuttingdiagram2d.to_hash
    end

    def cuttingdiagram2d_write_command(settings)
      require_relative '../worker/cutlist/cutlist_cuttingdiagram2d_write_worker'

      # Setup worker
      worker = CutlistCuttingdiagram2dWriteWorker.new(@cutlist, @cuttingdiagram2d, **settings)

      # Run !
      worker.run
    end

    def labels_command(settings)
      require_relative '../worker/cutlist/cutlist_labels_worker'

      # Setup worker
      worker = CutlistLabelsWorker.new(@cutlist, **settings)

      # Run !
      worker.run
    end

    def reset_prices_command
      require_relative '../worker/cutlist/cutlist_reset_prices_worker'

      # Setup worker
      worker = CutlistResetPricesWorker.new

      # Run !
      worker.run
    end


    def group_packing_start_command(settings)
      require_relative '../worker/cutlist/cutlist_packing_worker'

      # Setup worker
      @packing_worker = CutlistPackingWorker.new(@cutlist, **settings)

      # Run !
      packing = @packing_worker.run(:start)

      @packing = packing unless packing.running

      packing.to_hash
    end

    def group_packing_advance_command
      return { :errors => [ 'default.error' ] } unless @packing_worker

      # Run !
      packing = @packing_worker.run(:advance)

      @packing = packing unless packing.running

      packing.to_hash
    end

    def group_packing_cancel_command
      return { :errors => [ 'default.error' ] } unless @packing_worker

      # Run !
      packing = @packing_worker.run(:cancel)

      @packing = packing unless packing.running

      packing.to_hash
    end

    def packing_write_command(settings)
      require_relative '../worker/cutlist/cutlist_packing_write_worker'

      # Setup worker
      worker = CutlistPackingWriteWorker.new(@cutlist, @packing, **settings)

      # Run !
      worker.run
    end

  end

end