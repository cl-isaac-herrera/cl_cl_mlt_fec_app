class User < ApplicationRecord
  include Auditable
  include Clavisco::DataAccess::SoftDeletable

  # Cifrada en reposo, no hasheada: el Service Layer de SAP pide la contraseña en
  # claro para hacer /Login, así que tiene que poder descifrarse. Reemplaza al AES
  # que aplicaba el API .NET antes de llamar a `spUpdateUserInfo`.
  encrypts :sap_password

  has_many :users_by_companies, dependent: :destroy
  has_many :companies, through: :users_by_companies

  # Largos heredados del contrato del API .NET (PatchProfileInformationDto), para
  # que los datos sigan cabiendo cuando la base vuelva a ser SQL Server.
  validates :sap_user,              length: { maximum: 75 }, allow_blank: true
  validates :sap_password,          length: { maximum: 50 }, allow_blank: true
  validates :doc_number_preference, length: { maximum: 2 },  allow_blank: true
end
