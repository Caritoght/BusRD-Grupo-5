/* =====================================================================
   03_sp_AnularBoleto.sql  -  E2.5
   Anula un boleto y registra el REVERSO del pago (monto negativo).
   Todo en una transaccion: o se anula y se reversa, o no pasa nada.
   El boleto anulado sale del indice unico filtrado => el asiento queda libre.
   Codigos: 50010 boleto inexistente, 50011 boleto ya anulado.
   ===================================================================== */
USE BusRD;
GO
CREATE OR ALTER PROCEDURE dbo.sp_AnularBoleto
    @BoletoID INT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Estado VARCHAR(10), @Neto DECIMAL(10,2), @Metodo VARCHAR(15);

    BEGIN TRY
        BEGIN TRANSACTION;

            -- Bloquea la fila para que dos anulaciones simultaneas no reversen dos veces
            SELECT @Estado = Estado
            FROM dbo.Boletos WITH (UPDLOCK, HOLDLOCK)
            WHERE BoletoID = @BoletoID;

            IF @Estado IS NULL
                THROW 50010, 'El boleto no existe.', 1;
            IF @Estado = 'Anulado'
                THROW 50011, 'El boleto ya esta anulado.', 1;

            -- Monto neto realmente cobrado y metodo original
            SELECT @Neto = SUM(Monto) FROM dbo.Pagos WHERE BoletoID = @BoletoID;
            SELECT TOP (1) @Metodo = Metodo
            FROM dbo.Pagos
            WHERE BoletoID = @BoletoID AND Monto > 0
            ORDER BY PagoID;

            UPDATE dbo.Boletos SET Estado = 'Anulado' WHERE BoletoID = @BoletoID;

            IF ISNULL(@Neto, 0) > 0
                INSERT dbo.Pagos(BoletoID, Monto, Metodo, FechaPago)
                VALUES (@BoletoID, -@Neto, @Metodo, SYSDATETIME());

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO
