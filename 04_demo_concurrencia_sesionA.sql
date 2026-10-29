/* =====================================================================
   04_demo_concurrencia_sesionA.sql  -  VENTANA A de SSMS
   Ejecutar BLOQUE POR BLOQUE (seleccionar y F5), NO todo de golpe.
   La ventana B usa 05_demo_concurrencia_sesionB.sql.

   CONFIGURACION (repetida en cada bloque; usar los MISMOS valores en A y B):
     @ViajeID      = viaje asignado al grupo (debe estar 'Programado')
     @AsientoV0    = asiento LIBRE para la prueba con v0
     @AsientoNuevo = otro asiento LIBRE para la prueba con el procedimiento nuevo
   ===================================================================== */
USE BusRD;
GO

/* ---------------------------------------------------------------------
   PASO 0 - Preparacion (solo en A)
   a) comprobar viaje y elegir asientos libres
   b) DESHABILITAR temporalmente el indice unico (E2.1 exige reproducir el
      defecto ANTES de la restriccion de unicidad)
   --------------------------------------------------------------------- */
DECLARE @ViajeID INT = 16000;                       -- <<< CAMBIAR

SELECT ViajeID, Estado, FechaSalida FROM dbo.Viajes WHERE ViajeID = @ViajeID;

-- Asientos libres (elegir dos y copiarlos en los bloques siguientes)
SELECT TOP 10 s.NumeroAsiento, s.Ubicacion
FROM dbo.Viajes v
JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.ViajeID = @ViajeID
  AND NOT EXISTS (SELECT 1 FROM dbo.Boletos b
                  WHERE b.ViajeID = v.ViajeID AND b.NumeroAsiento = s.NumeroAsiento
                    AND b.Estado = 'Activo')
ORDER BY s.NumeroAsiento DESC;

IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = 'UX_Boletos_Viaje_Asiento_Activo'
             AND object_id = OBJECT_ID('dbo.Boletos') AND is_disabled = 0)
    ALTER INDEX UX_Boletos_Viaje_Asiento_Activo ON dbo.Boletos DISABLE;

IF OBJECT_ID('dbo.sp_VenderBoleto_v0') IS NULL
    THROW 50099, 'Falta crear sp_VenderBoleto_v0 (script 02 entregado por el docente).', 1;
GO

/* ---------------------------------------------------------------------
   PASO 1A - Venta con v0 desde la ventana A
   Lanzar A y, en MENOS DE 10 SEGUNDOS, lanzar el PASO 1B en la ventana B.
   --------------------------------------------------------------------- */
DECLARE @ViajeID INT = 16000, @AsientoV0 INT = 44;  -- <<< CAMBIAR

EXEC dbo.sp_VenderBoleto_v0
     @ViajeID = @ViajeID, @NumeroAsiento = @AsientoV0,
     @ClienteID = 1, @Canal = 'Taquilla', @Metodo = 'Efectivo';
PRINT 'Ventana A: venta terminada';
GO

/* ---------------------------------------------------------------------
   PASO 2 - EVIDENCIA de la doble venta (SELECT)  -> captura de pantalla
   Resultado esperado: 2 filas 'Activo' para el mismo viaje y asiento.
   --------------------------------------------------------------------- */
DECLARE @ViajeID INT = 16000, @AsientoV0 INT = 44;  -- <<< CAMBIAR

SELECT b.BoletoID, b.ViajeID, b.NumeroAsiento, b.ClienteID, b.Canal, b.Estado, b.FechaVenta,
       p.PagoID, p.Monto
FROM dbo.Boletos b
LEFT JOIN dbo.Pagos p ON p.BoletoID = b.BoletoID
WHERE b.ViajeID = @ViajeID AND b.NumeroAsiento = @AsientoV0
ORDER BY b.BoletoID;
GO

/* ---------------------------------------------------------------------
   PASO 3 - Reparar la doble venta y volver a activar la restriccion
   Se anula el boleto mas reciente con sp_AnularBoleto (reverso del pago) y
   se reconstruye el indice unico (fallaria si quedaran duplicados).
   --------------------------------------------------------------------- */
DECLARE @ViajeID INT = 16000, @AsientoV0 INT = 44;  -- <<< CAMBIAR
DECLARE @Dup INT = (SELECT MAX(BoletoID) FROM dbo.Boletos
                    WHERE ViajeID = @ViajeID AND NumeroAsiento = @AsientoV0 AND Estado = 'Activo');
EXEC dbo.sp_AnularBoleto @BoletoID = @Dup;

ALTER INDEX UX_Boletos_Viaje_Asiento_Activo ON dbo.Boletos REBUILD;

SELECT BoletoID, NumeroAsiento, Estado FROM dbo.Boletos
WHERE ViajeID = @ViajeID AND NumeroAsiento = @AsientoV0;
GO

/* ---------------------------------------------------------------------
   PASO 4A - Venta con el procedimiento NUEVO desde la ventana A
   @SimularDemora = 1 => retiene los bloqueos 10 s dentro de la transaccion.
   Lanzar A y, en MENOS DE 10 SEGUNDOS, el PASO 4B en la ventana B.
   Resultado esperado: A termina bien; B espera y luego es rechazada (50007).
   --------------------------------------------------------------------- */
DECLARE @ViajeID INT = 16000, @AsientoNuevo INT = 43;  -- <<< CAMBIAR
DECLARE @BoletoID INT, @t0 DATETIME2 = SYSDATETIME();

EXEC dbo.sp_VenderBoleto
     @ViajeID = @ViajeID, @NumeroAsiento = @AsientoNuevo,
     @ClienteID = 1, @Canal = 'Taquilla', @Metodo = 'Efectivo',
     @BoletoID = @BoletoID OUTPUT, @SimularDemora = 1;

SELECT @BoletoID AS BoletoID_A, DATEDIFF(MILLISECOND, @t0, SYSDATETIME()) AS Ms_Ventana_A;
GO

/* ---------------------------------------------------------------------
   PASO 5 - EVIDENCIA final: UN solo boleto activo para el asiento
   --------------------------------------------------------------------- */
DECLARE @ViajeID INT = 16000, @AsientoNuevo INT = 43;  -- <<< CAMBIAR

SELECT b.BoletoID, b.ClienteID, b.Canal, b.Estado, b.FechaVenta, p.Monto
FROM dbo.Boletos b
LEFT JOIN dbo.Pagos p ON p.BoletoID = b.BoletoID
WHERE b.ViajeID = @ViajeID AND b.NumeroAsiento = @AsientoNuevo;
GO

/* ---------------------------------------------------------------------
   OPCIONAL - Ventana C: mientras A y B corren (durante los 10 s), mostrar
   que B esta BLOQUEADA esperando a A
   --------------------------------------------------------------------- */
SELECT r.session_id, r.blocking_session_id, r.wait_type, r.wait_time AS wait_ms,
       r.status, SUBSTRING(t.text, 1, 80) AS Sentencia
FROM sys.dm_exec_requests r
CROSS APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.blocking_session_id <> 0;
GO
