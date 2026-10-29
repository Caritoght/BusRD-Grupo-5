/* =====================================================================
   01_integridad.sql  -  E1. Integridad del modelo (Unidad I)
   Ejecutar sobre una base recien creada con el script 01 entregado.
   Orden: 1) detectar  2) limpiar  3) FK  4) CHECK  5) UNIQUE
          6) indice unico filtrado (un solo boleto ACTIVO por asiento/viaje)
   ===================================================================== */
USE BusRD;
GO
SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------
   1. DETECCION DE DATOS SUCIOS
   --------------------------------------------------------------------- */

-- 1.1 Boletos ACTIVOS duplicados (mismo viaje y mismo asiento)
SELECT ViajeID, NumeroAsiento,
       COUNT(*)      AS VecesVendido,
       MIN(BoletoID) AS BoletoOriginal,
       MAX(BoletoID) AS BoletoDuplicado
FROM dbo.Boletos
WHERE Estado = 'Activo'
GROUP BY ViajeID, NumeroAsiento
HAVING COUNT(*) > 1
ORDER BY ViajeID, NumeroAsiento;

SELECT COUNT(*) AS GruposDuplicados                      -- esperado: 60
FROM (SELECT 1 AS x FROM dbo.Boletos WHERE Estado = 'Activo'
      GROUP BY ViajeID, NumeroAsiento HAVING COUNT(*) > 1) t;

-- 1.2 Pagos huerfanos (apuntan a un BoletoID que no existe)
SELECT p.PagoID, p.BoletoID, p.Monto, p.Metodo, p.FechaPago
FROM dbo.Pagos p
WHERE NOT EXISTS (SELECT 1 FROM dbo.Boletos b WHERE b.BoletoID = p.BoletoID);

SELECT COUNT(*) AS PagosHuerfanos                        -- esperado: 15
FROM dbo.Pagos p
WHERE NOT EXISTS (SELECT 1 FROM dbo.Boletos b WHERE b.BoletoID = p.BoletoID);

-- 1.3 Otras verificaciones previas a las llaves foraneas y CHECK (todas deben dar 0)
SELECT 'Viajes sin Ruta'           AS Revision, COUNT(*) AS Filas FROM dbo.Viajes v   WHERE NOT EXISTS (SELECT 1 FROM dbo.Rutas r      WHERE r.RutaID = v.RutaID)
UNION ALL SELECT 'Viajes sin Autobus',     COUNT(*) FROM dbo.Viajes v   WHERE NOT EXISTS (SELECT 1 FROM dbo.Autobuses a  WHERE a.AutobusID = v.AutobusID)
UNION ALL SELECT 'Asientos sin Autobus',   COUNT(*) FROM dbo.Asientos s WHERE NOT EXISTS (SELECT 1 FROM dbo.Autobuses a  WHERE a.AutobusID = s.AutobusID)
UNION ALL SELECT 'Boletos sin Viaje',      COUNT(*) FROM dbo.Boletos b  WHERE NOT EXISTS (SELECT 1 FROM dbo.Viajes v     WHERE v.ViajeID = b.ViajeID)
UNION ALL SELECT 'Boletos sin Cliente',    COUNT(*) FROM dbo.Boletos b  WHERE NOT EXISTS (SELECT 1 FROM dbo.Clientes c   WHERE c.ClienteID = b.ClienteID)
UNION ALL SELECT 'Boletos con asiento inexistente en el autobus del viaje', COUNT(*)
          FROM dbo.Boletos b JOIN dbo.Viajes v ON v.ViajeID = b.ViajeID
          WHERE NOT EXISTS (SELECT 1 FROM dbo.Asientos s WHERE s.AutobusID = v.AutobusID AND s.NumeroAsiento = b.NumeroAsiento)
UNION ALL SELECT 'Cedulas duplicadas',     COUNT(*) FROM (SELECT Cedula FROM dbo.Clientes   GROUP BY Cedula HAVING COUNT(*) > 1) t
UNION ALL SELECT 'Placas duplicadas',      COUNT(*) FROM (SELECT Placa  FROM dbo.Autobuses  GROUP BY Placa  HAVING COUNT(*) > 1) t
UNION ALL SELECT 'Boletos.Estado invalido',COUNT(*) FROM dbo.Boletos   WHERE Estado NOT IN ('Activo','Anulado')
UNION ALL SELECT 'Boletos.Canal invalido', COUNT(*) FROM dbo.Boletos   WHERE Canal  NOT IN ('Taquilla','Web')
UNION ALL SELECT 'Pagos.Metodo invalido',  COUNT(*) FROM dbo.Pagos     WHERE Metodo NOT IN ('Efectivo','Tarjeta','Transferencia')
UNION ALL SELECT 'Viajes.Estado invalido', COUNT(*) FROM dbo.Viajes    WHERE Estado NOT IN ('Programado','Completado','Cancelado')
UNION ALL SELECT 'Autobuses.Tipo invalido',COUNT(*) FROM dbo.Autobuses WHERE Tipo   NOT IN ('Estandar','Ejecutivo')
UNION ALL SELECT 'Precios/Montos fuera de rango', COUNT(*)
          FROM (SELECT Precio AS v FROM dbo.Boletos WHERE Precio <= 0
                UNION ALL SELECT Monto FROM dbo.Pagos WHERE Monto = 0) t;
GO

/* ---------------------------------------------------------------------
   2. LIMPIEZA (una sola transaccion, con bitacora)
   REGLA 1 (duplicados): se conserva la venta MAS ANTIGUA (menor FechaVenta,
     desempate por BoletoID) porque fue la que primero obtuvo el asiento.
     Las ventas posteriores se ANULAN (no se borran: se conserva la
     trazabilidad) y su pago se REVERSA con un pago de monto negativo,
     igual que hara sp_AnularBoleto (el cliente debe ser reembolsado).
   REGLA 2 (pagos huerfanos): no se puede saber a que venta pertenecen.
     Se copian a una tabla de CUARENTENA para auditoria y se eliminan de
     Pagos (si no, la llave foranea no se puede crear).
   --------------------------------------------------------------------- */
IF OBJECT_ID('dbo.LimpiezaLog') IS NULL
    CREATE TABLE dbo.LimpiezaLog(
        LogID      INT IDENTITY PRIMARY KEY,
        Fecha      DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME(),
        Tabla      VARCHAR(30)   NOT NULL,
        RegistroID INT           NOT NULL,
        Accion     VARCHAR(60)   NOT NULL,
        Detalle    VARCHAR(200)  NULL
    );
GO

BEGIN TRY
    BEGIN TRANSACTION;

    -- 2.1 Duplicados: todo boleto activo que NO sea el primero de su (viaje, asiento)
    IF OBJECT_ID('tempdb..#Dup') IS NOT NULL DROP TABLE #Dup;
    SELECT BoletoID
    INTO #Dup
    FROM (SELECT BoletoID,
                 ROW_NUMBER() OVER (PARTITION BY ViajeID, NumeroAsiento
                                    ORDER BY FechaVenta, BoletoID) AS rn
          FROM dbo.Boletos
          WHERE Estado = 'Activo') x
    WHERE rn > 1;

    UPDATE b SET Estado = 'Anulado'
    FROM dbo.Boletos b
    JOIN #Dup d ON d.BoletoID = b.BoletoID;

    INSERT dbo.Pagos(BoletoID, Monto, Metodo, FechaPago)
    SELECT p.BoletoID, -p.Monto, p.Metodo, SYSDATETIME()
    FROM dbo.Pagos p
    JOIN #Dup d ON d.BoletoID = p.BoletoID
    WHERE p.Monto > 0;

    INSERT dbo.LimpiezaLog(Tabla, RegistroID, Accion, Detalle)
    SELECT 'Boletos', BoletoID, 'Anulado por duplicado',
           'Se conserva la venta mas antigua; pago reversado con monto negativo'
    FROM #Dup;

    -- 2.2 Pagos huerfanos -> cuarentena y eliminacion
    IF OBJECT_ID('dbo.Pagos_Huerfanos_Cuarentena') IS NOT NULL DROP TABLE dbo.Pagos_Huerfanos_Cuarentena;
    SELECT p.*
    INTO dbo.Pagos_Huerfanos_Cuarentena
    FROM dbo.Pagos p
    WHERE NOT EXISTS (SELECT 1 FROM dbo.Boletos b WHERE b.BoletoID = p.BoletoID);

    INSERT dbo.LimpiezaLog(Tabla, RegistroID, Accion, Detalle)
    SELECT 'Pagos', PagoID, 'Movido a cuarentena y eliminado',
           'Pago sin boleto. Copia en dbo.Pagos_Huerfanos_Cuarentena'
    FROM dbo.Pagos_Huerfanos_Cuarentena;

    DELETE p
    FROM dbo.Pagos p
    JOIN dbo.Pagos_Huerfanos_Cuarentena q ON q.PagoID = p.PagoID;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO

-- Resumen de la limpieza
SELECT Tabla, Accion, COUNT(*) AS Registros
FROM dbo.LimpiezaLog GROUP BY Tabla, Accion;
GO

/* ---------------------------------------------------------------------
   3. LLAVES FORANEAS
   Nota: Boletos(ViajeID, NumeroAsiento) no puede tener FK a Asientos porque
   Boletos no guarda AutobusID (el autobus se obtiene por el viaje). Esa
   relacion se valida dentro de sp_VenderBoleto.
   --------------------------------------------------------------------- */
ALTER TABLE dbo.Viajes   WITH CHECK ADD CONSTRAINT FK_Viajes_Rutas     FOREIGN KEY (RutaID)    REFERENCES dbo.Rutas(RutaID);
ALTER TABLE dbo.Viajes   WITH CHECK ADD CONSTRAINT FK_Viajes_Autobuses FOREIGN KEY (AutobusID) REFERENCES dbo.Autobuses(AutobusID);
ALTER TABLE dbo.Asientos WITH CHECK ADD CONSTRAINT FK_Asientos_Autobuses FOREIGN KEY (AutobusID) REFERENCES dbo.Autobuses(AutobusID);
ALTER TABLE dbo.Boletos  WITH CHECK ADD CONSTRAINT FK_Boletos_Viajes   FOREIGN KEY (ViajeID)   REFERENCES dbo.Viajes(ViajeID);
ALTER TABLE dbo.Boletos  WITH CHECK ADD CONSTRAINT FK_Boletos_Clientes FOREIGN KEY (ClienteID) REFERENCES dbo.Clientes(ClienteID);
ALTER TABLE dbo.Pagos    WITH CHECK ADD CONSTRAINT FK_Pagos_Boletos    FOREIGN KEY (BoletoID)  REFERENCES dbo.Boletos(BoletoID);
GO

/* ---------------------------------------------------------------------
   4. RESTRICCIONES CHECK
   Monto permite negativos (reversos de pago) pero no cero.
   --------------------------------------------------------------------- */
ALTER TABLE dbo.Viajes    WITH CHECK ADD CONSTRAINT CK_Viajes_Estado     CHECK (Estado IN ('Programado','Completado','Cancelado'));
ALTER TABLE dbo.Boletos   WITH CHECK ADD CONSTRAINT CK_Boletos_Estado    CHECK (Estado IN ('Activo','Anulado'));
ALTER TABLE dbo.Boletos   WITH CHECK ADD CONSTRAINT CK_Boletos_Canal     CHECK (Canal  IN ('Taquilla','Web'));
ALTER TABLE dbo.Pagos     WITH CHECK ADD CONSTRAINT CK_Pagos_Metodo      CHECK (Metodo IN ('Efectivo','Tarjeta','Transferencia'));
ALTER TABLE dbo.Autobuses WITH CHECK ADD CONSTRAINT CK_Autobuses_Tipo    CHECK (Tipo   IN ('Estandar','Ejecutivo'));
ALTER TABLE dbo.Asientos  WITH CHECK ADD CONSTRAINT CK_Asientos_Ubicacion CHECK (Ubicacion IN ('Ventana','Pasillo'));

ALTER TABLE dbo.Boletos   WITH CHECK ADD CONSTRAINT CK_Boletos_Precio    CHECK (Precio > 0 AND Precio <= 10000);
ALTER TABLE dbo.Pagos     WITH CHECK ADD CONSTRAINT CK_Pagos_Monto       CHECK (Monto <> 0 AND ABS(Monto) <= 10000);
ALTER TABLE dbo.Autobuses WITH CHECK ADD CONSTRAINT CK_Autobuses_Capacidad CHECK (Capacidad BETWEEN 1 AND 60);
ALTER TABLE dbo.Rutas     WITH CHECK ADD CONSTRAINT CK_Rutas_PrecioBase  CHECK (PrecioBase > 0);
ALTER TABLE dbo.Rutas     WITH CHECK ADD CONSTRAINT CK_Rutas_Distancia   CHECK (DistanciaKm > 0);
GO

/* ---------------------------------------------------------------------
   5. UNICIDAD
   --------------------------------------------------------------------- */
ALTER TABLE dbo.Clientes  ADD CONSTRAINT UQ_Clientes_Cedula  UNIQUE (Cedula);
ALTER TABLE dbo.Autobuses ADD CONSTRAINT UQ_Autobuses_Placa  UNIQUE (Placa);
GO

/* ---------------------------------------------------------------------
   6. UN SOLO BOLETO ACTIVO POR ASIENTO Y VIAJE
   Indice unico FILTRADO: solo indexa las filas con Estado = 'Activo'.
   Un boleto anulado sale del indice, asi que libera el asiento.
   (Requiere SET QUOTED_IDENTIFIER ON; SSMS lo trae por defecto.)
   --------------------------------------------------------------------- */
CREATE UNIQUE NONCLUSTERED INDEX UX_Boletos_Viaje_Asiento_Activo
    ON dbo.Boletos(ViajeID, NumeroAsiento)
    WHERE Estado = 'Activo';
GO

/* ---------------------------------------------------------------------
   7. VERIFICACION FINAL
   --------------------------------------------------------------------- */
SELECT COUNT(*) AS DuplicadosActivos_Restantes           -- esperado: 0
FROM (SELECT 1 AS x FROM dbo.Boletos WHERE Estado = 'Activo'
      GROUP BY ViajeID, NumeroAsiento HAVING COUNT(*) > 1) t;

SELECT COUNT(*) AS PagosHuerfanos_Restantes              -- esperado: 0
FROM dbo.Pagos p
WHERE NOT EXISTS (SELECT 1 FROM dbo.Boletos b WHERE b.BoletoID = p.BoletoID);

SELECT OBJECT_NAME(parent_object_id) AS Tabla, name AS Restriccion, type_desc
FROM sys.objects
WHERE type IN ('F','C','UQ') AND parent_object_id IN (SELECT object_id FROM sys.tables)
ORDER BY type_desc, Tabla, Restriccion;

-- Prueba rapida: intentar duplicar un asiento activo debe fallar (error 2601)
BEGIN TRY
    DECLARE @v INT, @a INT;
    SELECT TOP 1 @v = ViajeID, @a = NumeroAsiento FROM dbo.Boletos WHERE Estado = 'Activo';
    INSERT dbo.Boletos(ViajeID,NumeroAsiento,ClienteID,FechaVenta,Canal,Precio,Estado)
    VALUES (@v,@a,1,SYSDATETIME(),'Web',100,'Activo');
    SELECT 'ERROR: se permitio la doble venta' AS Resultado;
END TRY
BEGIN CATCH
    SELECT 'OK: la BD rechazo el duplicado' AS Resultado, ERROR_NUMBER() AS Numero, ERROR_MESSAGE() AS Mensaje;
END CATCH;
GO
