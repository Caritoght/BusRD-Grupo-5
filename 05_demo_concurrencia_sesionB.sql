/* =====================================================================
   05_demo_concurrencia_sesionB.sql  -  VENTANA B de SSMS
   Usar los MISMOS valores de viaje y asientos que en la ventana A.
   Lanzar cada bloque a los pocos segundos de haber lanzado el de A.
   ===================================================================== */
USE BusRD;
GO

/* ---------------------------------------------------------------------
   PASO 1B - Venta con v0 desde la ventana B (misma asiento que A)
   Resultado esperado: NO da error. Las dos ventas se completan (doble venta).
   --------------------------------------------------------------------- */
DECLARE @ViajeID INT = 16000, @AsientoV0 INT = 44;  -- <<< igual que en A

EXEC dbo.sp_VenderBoleto_v0
     @ViajeID = @ViajeID, @NumeroAsiento = @AsientoV0,
     @ClienteID = 2, @Canal = 'Web', @Metodo = 'Tarjeta';
PRINT 'Ventana B: venta terminada (v0 permitio la doble venta)';
GO

/* ---------------------------------------------------------------------
   PASO 4B - Venta con el procedimiento NUEVO desde la ventana B
   Resultado esperado: B ESPERA ~10 s (bloqueada por A) y luego recibe el
   error 50007 'El asiento ya esta vendido.'. Nada queda insertado.
   --------------------------------------------------------------------- */
DECLARE @ViajeID INT = 16000, @AsientoNuevo INT = 43;  -- <<< igual que en A
DECLARE @BoletoID INT, @t0 DATETIME2 = SYSDATETIME();

BEGIN TRY
    EXEC dbo.sp_VenderBoleto
         @ViajeID = @ViajeID, @NumeroAsiento = @AsientoNuevo,
         @ClienteID = 2, @Canal = 'Web', @Metodo = 'Tarjeta',
         @BoletoID = @BoletoID OUTPUT, @SimularDemora = 0;
    SELECT 'B vendio (NO deberia pasar)' AS Resultado, @BoletoID AS BoletoID;
END TRY
BEGIN CATCH
    SELECT 'B RECHAZADA' AS Resultado,
           ERROR_NUMBER()  AS Numero,
           ERROR_MESSAGE() AS Mensaje,
           DATEDIFF(MILLISECOND, @t0, SYSDATETIME()) AS Ms_Espera;   -- ~10000 ms
END CATCH;
GO
