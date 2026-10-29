/* =====================================================================
   07_seguridad.sql  -  E4. Seguridad (Unidad III)
   Principio de MINIMO PRIVILEGIO: cada rol recibe solo lo que necesita.
   OWNERSHIP CHAINING: los procedimientos y vistas pertenecen a dbo, igual
   que las tablas. Cuando un objeto de dbo llama a otro objeto de dbo, SQL
   Server solo verifica el permiso sobre el objeto que se invoca (el SP o la
   vista), NO sobre las tablas subyacentes. Por eso rol_taquilla puede vender
   sin tener ningun permiso sobre dbo.Boletos o dbo.Pagos.
   La cadena se rompe con SQL dinamico (EXEC(...)) o si el dueno es otro.
   Requiere haber ejecutado 02 y 03 (los procedimientos).
   ===================================================================== */
USE BusRD;
GO

/* ---------------- Vistas ---------------- */
CREATE OR ALTER VIEW dbo.vw_AsientosDisponibles
AS
SELECT v.ViajeID, v.FechaSalida, r.Origen, r.Destino, s.NumeroAsiento, s.Ubicacion
FROM dbo.Viajes v
JOIN dbo.Rutas   r ON r.RutaID    = v.RutaID
JOIN dbo.Asientos s ON s.AutobusID = v.AutobusID
WHERE v.Estado = 'Programado'
  AND NOT EXISTS (SELECT 1 FROM dbo.Boletos b
                  WHERE b.ViajeID = v.ViajeID
                    AND b.NumeroAsiento = s.NumeroAsiento
                    AND b.Estado = 'Activo');
GO

CREATE OR ALTER VIEW dbo.vw_VentasMensuales
AS
SELECT YEAR(b.FechaVenta)  AS Anio,
       MONTH(b.FechaVenta) AS Mes,
       r.Origen, r.Destino,
       COUNT(*)            AS Boletos,
       SUM(p.Monto)        AS Ingresos
FROM dbo.Boletos b
JOIN dbo.Pagos  p ON p.BoletoID = b.BoletoID
JOIN dbo.Viajes v ON v.ViajeID  = b.ViajeID
JOIN dbo.Rutas  r ON r.RutaID   = v.RutaID
WHERE b.Estado = 'Activo'
GROUP BY YEAR(b.FechaVenta), MONTH(b.FechaVenta), r.Origen, r.Destino;
GO

/* ---------------- Roles ---------------- */
IF DATABASE_PRINCIPAL_ID('rol_taquilla') IS NULL CREATE ROLE rol_taquilla;
IF DATABASE_PRINCIPAL_ID('rol_reportes') IS NULL CREATE ROLE rol_reportes;
IF DATABASE_PRINCIPAL_ID('rol_admin')    IS NULL CREATE ROLE rol_admin;
GO

/* rol_taquilla: solo EXECUTE de 2 procedimientos y SELECT de 1 vista */
GRANT EXECUTE ON OBJECT::dbo.sp_VenderBoleto         TO rol_taquilla;
GRANT EXECUTE ON OBJECT::dbo.sp_AnularBoleto         TO rol_taquilla;
GRANT SELECT  ON OBJECT::dbo.vw_AsientosDisponibles  TO rol_taquilla;

/* rol_reportes: solo SELECT de la vista. DENY explicito de columnas sensibles
   (defensa en profundidad: aunque luego alguien le diera SELECT sobre Clientes,
   Email y Telefono seguirian bloqueados). */
GRANT SELECT ON OBJECT::dbo.vw_VentasMensuales TO rol_reportes;
DENY  SELECT ON OBJECT::dbo.Clientes(Email, Telefono) TO rol_reportes;

/* rol_admin: administracion completa de la base */
ALTER ROLE db_owner ADD MEMBER rol_admin;
GO

/* ---------------- Usuarios de prueba (sin login) ---------------- */
IF DATABASE_PRINCIPAL_ID('usr_taquilla') IS NULL CREATE USER usr_taquilla WITHOUT LOGIN;
IF DATABASE_PRINCIPAL_ID('usr_reportes') IS NULL CREATE USER usr_reportes WITHOUT LOGIN;
IF DATABASE_PRINCIPAL_ID('usr_admin')    IS NULL CREATE USER usr_admin    WITHOUT LOGIN;
ALTER ROLE rol_taquilla ADD MEMBER usr_taquilla;
ALTER ROLE rol_reportes ADD MEMBER usr_reportes;
ALTER ROLE rol_admin    ADD MEMBER usr_admin;
GO

/* =====================================================================
   PRUEBAS  (hacer captura de cada resultado / mensaje de error)
   ===================================================================== */

/* ---------- rol_taquilla ---------- */
-- Asiento libre de un viaje programado, elegido como dbo
DECLARE @V INT, @A INT, @B INT;
SELECT TOP 1 @V = ViajeID, @A = NumeroAsiento
FROM dbo.vw_AsientosDisponibles ORDER BY ViajeID DESC, NumeroAsiento DESC;

EXECUTE AS USER = 'usr_taquilla';
    SELECT 'taquilla - PERMITIDO 1: SELECT a la vista' AS Prueba, SUSER_NAME() AS Contexto, USER_NAME() AS Usuario;
    SELECT TOP 5 * FROM dbo.vw_AsientosDisponibles WHERE ViajeID = @V;

    BEGIN TRY   -- PERMITIDO 2: vender SIN permisos sobre las tablas (ownership chaining)
        EXEC dbo.sp_VenderBoleto @ViajeID = @V, @NumeroAsiento = @A, @ClienteID = 1,
             @Canal = 'Taquilla', @Metodo = 'Efectivo', @BoletoID = @B OUTPUT;
        SELECT 'taquilla - PERMITIDO 2: sp_VenderBoleto' AS Prueba, @B AS BoletoID;
    END TRY
    BEGIN CATCH
        SELECT 'taquilla - ERROR inesperado' AS Prueba, ERROR_NUMBER() AS Numero, ERROR_MESSAGE() AS Mensaje;
    END CATCH;

    BEGIN TRY   -- PERMITIDO 3: anular el boleto que acaba de vender
        EXEC dbo.sp_AnularBoleto @BoletoID = @B;
        SELECT 'taquilla - PERMITIDO 3: sp_AnularBoleto' AS Prueba, @B AS BoletoAnulado;
    END TRY
    BEGIN CATCH
        SELECT 'taquilla - ERROR inesperado' AS Prueba, ERROR_NUMBER() AS Numero, ERROR_MESSAGE() AS Mensaje;
    END CATCH;

    BEGIN TRY   -- DENEGADO 1
        SELECT TOP 5 * FROM dbo.Boletos;
    END TRY
    BEGIN CATCH
        SELECT 'taquilla - DENEGADO 1: SELECT dbo.Boletos' AS Prueba, ERROR_NUMBER() AS Numero, ERROR_MESSAGE() AS Mensaje;
    END CATCH;

    BEGIN TRY   -- DENEGADO 2
        SELECT TOP 5 Cedula, Email FROM dbo.Clientes;
    END TRY
    BEGIN CATCH
        SELECT 'taquilla - DENEGADO 2: SELECT dbo.Clientes' AS Prueba, ERROR_NUMBER() AS Numero, ERROR_MESSAGE() AS Mensaje;
    END CATCH;

    BEGIN TRY   -- DENEGADO 3
        DELETE FROM dbo.Boletos WHERE BoletoID = -1;
    END TRY
    BEGIN CATCH
        SELECT 'taquilla - DENEGADO 3: DELETE dbo.Boletos' AS Prueba, ERROR_NUMBER() AS Numero, ERROR_MESSAGE() AS Mensaje;
    END CATCH;
REVERT;
GO

/* ---------- rol_reportes ---------- */
EXECUTE AS USER = 'usr_reportes';
    SELECT 'reportes - PERMITIDO 1: SELECT a la vista' AS Prueba;
    SELECT TOP 10 * FROM dbo.vw_VentasMensuales ORDER BY Anio, Mes, Origen;

    SELECT 'reportes - PERMITIDO 2: ingresos por anio' AS Prueba;
    SELECT Anio, SUM(Boletos) AS Boletos, SUM(Ingresos) AS Ingresos
    FROM dbo.vw_VentasMensuales GROUP BY Anio ORDER BY Anio;

    BEGIN TRY   -- DENEGADO 1: columnas sensibles
        SELECT TOP 5 Email, Telefono FROM dbo.Clientes;
    END TRY
    BEGIN CATCH
        SELECT 'reportes - DENEGADO 1: Email/Telefono de Clientes' AS Prueba, ERROR_NUMBER() AS Numero, ERROR_MESSAGE() AS Mensaje;
    END CATCH;

    BEGIN TRY   -- DENEGADO 2: tablas
        SELECT TOP 5 * FROM dbo.Boletos;
    END TRY
    BEGIN CATCH
        SELECT 'reportes - DENEGADO 2: SELECT dbo.Boletos' AS Prueba, ERROR_NUMBER() AS Numero, ERROR_MESSAGE() AS Mensaje;
    END CATCH;

    BEGIN TRY   -- DENEGADO 3: no puede vender
        DECLARE @B2 INT;
        EXEC dbo.sp_VenderBoleto @ViajeID = 1, @NumeroAsiento = 1, @ClienteID = 1,
             @Canal = 'Web', @Metodo = 'Tarjeta', @BoletoID = @B2 OUTPUT;
    END TRY
    BEGIN CATCH
        SELECT 'reportes - DENEGADO 3: EXEC sp_VenderBoleto' AS Prueba, ERROR_NUMBER() AS Numero, ERROR_MESSAGE() AS Mensaje;
    END CATCH;
REVERT;
GO

/* ---------- rol_admin ---------- */
EXECUTE AS USER = 'usr_admin';
    SELECT 'admin - PERMITIDO 1: lectura completa' AS Prueba, COUNT(*) AS Boletos FROM dbo.Boletos;
    SELECT TOP 3 Cedula, Nombre, Email, Telefono FROM dbo.Clientes;

    BEGIN TRY   -- PERMITIDO 2: cambios de esquema en la base
        CREATE TABLE dbo.zz_prueba_admin(id INT);
        DROP TABLE dbo.zz_prueba_admin;
        SELECT 'admin - PERMITIDO 2: CREATE/DROP TABLE' AS Prueba;
    END TRY
    BEGIN CATCH
        SELECT 'admin - ERROR inesperado' AS Prueba, ERROR_NUMBER() AS Numero, ERROR_MESSAGE() AS Mensaje;
    END CATCH;

    BEGIN TRY   -- DENEGADO 1: db_owner no es sysadmin; fuera de la base no manda
        CREATE LOGIN lg_prueba WITH PASSWORD = 'Pru3ba#Segura2026';
        SELECT 'admin - CREATE LOGIN se permitio (revisar)' AS Prueba;
    END TRY
    BEGIN CATCH
        SELECT 'admin - DENEGADO 1: CREATE LOGIN (nivel servidor)' AS Prueba, ERROR_NUMBER() AS Numero, ERROR_MESSAGE() AS Mensaje;
    END CATCH;

    BEGIN TRY   -- DENEGADO 2: otra base de datos
        SELECT TOP 1 name FROM master.sys.sql_logins;
        SELECT 'admin - consulta a master devolvio filas/vacio (ver permisos)' AS Prueba;
    END TRY
    BEGIN CATCH
        SELECT 'admin - DENEGADO 2: leer logins del servidor' AS Prueba, ERROR_NUMBER() AS Numero, ERROR_MESSAGE() AS Mensaje;
    END CATCH;
REVERT;
GO

/* ---------- Matriz de permisos (para el informe) ---------- */
SELECT dp.name AS Principal, o.name AS Objeto, p.permission_name AS Permiso, p.state_desc AS Estado
FROM sys.database_permissions p
JOIN sys.database_principals dp ON dp.principal_id = p.grantee_principal_id
LEFT JOIN sys.objects o         ON o.object_id = p.major_id AND p.class = 1
WHERE dp.name IN ('rol_taquilla','rol_reportes','rol_admin')
ORDER BY dp.name, o.name, p.permission_name;

SELECT r.name AS Rol, m.name AS Miembro
FROM sys.database_role_members rm
JOIN sys.database_principals r ON r.principal_id = rm.role_principal_id
JOIN sys.database_principals m ON m.principal_id = rm.member_principal_id
WHERE r.name IN ('rol_taquilla','rol_reportes','rol_admin','db_owner')
ORDER BY r.name, m.name;
GO
