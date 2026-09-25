# frozen_string_literal: true

require 'rails_helper'

RSpec.describe MailReceptionJob do
  # Doble mínimo de `Net::IMAP`: alcanza con `uid_search`/`uid_fetch`/`uid_store`,
  # que es todo lo que el job usa. `attachments_from` se deja estubado (ver
  # `before`) para que este spec pruebe la LÓGICA del job —límites, orden,
  # marcado de \Seen— sin depender de `MailReception::IncomingDocument`, que ya
  # tiene su propio spec.
  class FakeImap
    attr_reader :marked_seen

    def initialize(uids:)
      @uids = uids
      @marked_seen = []
    end

    def uid_search(_criteria) = @uids

    def uid_fetch(uid, _data_item)
      [Struct.new(:attr).new({ 'RFC822' => "raw-#{uid}" })]
    end

    def uid_store(uid, _flag_op, _flags)
      @marked_seen << uid
    end
  end

  let(:mailbox1) { ReceptionMailbox.create!(mail_server: 'imap1.test', email: 'a@test.com', port: 993, password: 'x') }
  let(:mailbox2) { ReceptionMailbox.create!(mail_server: 'imap2.test', email: 'b@test.com', port: 993, password: 'x') }

  # Sustituye `MailReception::ImapSession.new(mailbox).open { |imap| ... }` por
  # una sesión falsa, indexada por bandeja. Una bandeja sin doble registrado
  # revienta el spec en vez de intentar una conexión real — es justamente la
  # señal que necesitan los ejemplos del límite duro (§ "no abre las bandejas
  # que faltan").
  def stub_sessions(mapping)
    allow(MailReception::ImapSession).to receive(:new) do |mailbox|
      imap = mapping.fetch(mailbox.id) { raise "sesión no esperada para #{mailbox.email}" }
      instance_double(MailReception::ImapSession, open: nil).tap do |session|
        allow(session).to receive(:open).and_yield(imap)
      end
    end
  end

  def set_limit(code, value)
    Setting.find_by(code: "MAIL_RECEPTION_#{code}").update_value!(value)
  end

  before do
    allow(MailReception::IncomingDocument).to receive(:attachments_from).and_return([])
  end

  describe 'sin ejecuciones paralelas' do
    it 'limita la concurrencia a una sola ejecución' do
      expect(described_class.concurrency_limit).to eq(1)
      expect(described_class.concurrency_duration).to eq(15.minutes)
    end
  end

  describe 'límite blando (por bandeja)' do
    it 'no toma más correos de UNA bandeja que el tope configurado' do
      set_limit('MAX_MESSAGES_PER_MAILBOX', '2')
      imap = FakeImap.new(uids: [1, 2, 3, 4])
      stub_sessions(mailbox1.id => imap)

      described_class.perform_now

      expect(imap.marked_seen).to eq([1, 2])
    end

    it 'una bandeja que agota su tope no afecta a las demás' do
      set_limit('MAX_MESSAGES_PER_MAILBOX', '1')
      imap1 = FakeImap.new(uids: [1, 2])
      imap2 = FakeImap.new(uids: [10, 20])
      stub_sessions(mailbox1.id => imap1, mailbox2.id => imap2)

      described_class.perform_now

      expect(imap1.marked_seen).to eq([1])
      expect(imap2.marked_seen).to eq([10])
    end
  end

  describe 'límite duro (por corrida)' do
    it 'detiene la corrida a mitad de una bandeja y no abre las que faltan' do
      set_limit('MAX_MESSAGES_PER_MAILBOX', '10')
      set_limit('MAX_MESSAGES_PER_EXECUTION', '2')
      imap1 = FakeImap.new(uids: [1, 2, 3])
      # mailbox2 NO se registra: si el job intentara abrirla, `stub_sessions`
      # revienta con "sesión no esperada".
      stub_sessions(mailbox1.id => imap1)
      mailbox2 # crear la segunda bandeja activa, sin doble de sesión

      described_class.perform_now

      expect(imap1.marked_seen).to eq([1, 2])
    end
  end

  describe 'orden de trabajo (oldest_first)' do
    it 'procesa primero la bandeja que lleva más tiempo sin procesarse' do
      mailbox1.update_column(:last_processed_at, 1.hour.ago)
      mailbox2 # nunca procesada (`last_processed_at` en NULL) → va primero

      order = []
      allow(MailReception::ImapSession).to receive(:new) do |mailbox|
        order << mailbox.id
        instance_double(MailReception::ImapSession).tap do |session|
          allow(session).to receive(:open).and_yield(FakeImap.new(uids: []))
        end
      end

      described_class.perform_now

      expect(order).to eq([mailbox2.id, mailbox1.id])
    end

    it 'la bandeja que el límite duro dejó sin tocar pasa primero en la corrida siguiente' do
      set_limit('MAX_MESSAGES_PER_MAILBOX', '10')
      set_limit('MAX_MESSAGES_PER_EXECUTION', '2')
      stub_sessions(mailbox1.id => FakeImap.new(uids: [1, 2]))
      mailbox2 # nunca llega a abrirse en esta corrida (ver el límite duro más abajo)

      described_class.perform_now

      expect(mailbox1.reload.last_processed_at).not_to be_nil
      expect(mailbox2.reload.last_processed_at).to be_nil

      # Corrida siguiente, ya sin el tope duro: mailbox2 tiene que ir primero
      # precisamente porque quedó pendiente la vez anterior.
      set_limit('MAX_MESSAGES_PER_EXECUTION', nil)
      order = []
      allow(MailReception::ImapSession).to receive(:new) do |mailbox|
        order << mailbox.id
        instance_double(MailReception::ImapSession).tap do |session|
          allow(session).to receive(:open).and_yield(FakeImap.new(uids: []))
        end
      end

      described_class.perform_now

      expect(order).to eq([mailbox2.id, mailbox1.id])
    end
  end

  describe '`last_processed_at`' do
    it 'se actualiza al terminar de procesar una bandeja' do
      imap = FakeImap.new(uids: [1])
      stub_sessions(mailbox1.id => imap)

      before_run = Time.current
      described_class.perform_now

      expect(mailbox1.reload.last_processed_at).to be_between(before_run, Time.current)
    end

    it 'se actualiza también cuando la bandeja no conecta' do
      allow(MailReception::ImapSession).to receive(:new).with(mailbox1)
        .and_raise(MailReception::ImapSession::ConnectionError, 'no se pudo conectar')

      before_run = Time.current
      described_class.perform_now

      expect(mailbox1.reload.last_processed_at).to be_between(before_run, Time.current)
    end

    it 'NO se actualiza en una bandeja que el límite duro deja sin tocar' do
      set_limit('MAX_MESSAGES_PER_MAILBOX', '10')
      set_limit('MAX_MESSAGES_PER_EXECUTION', '1')
      stub_sessions(mailbox1.id => FakeImap.new(uids: [1, 2]))
      mailbox2 # segunda bandeja activa, nunca llega a abrirse

      described_class.perform_now

      expect(mailbox2.reload.last_processed_at).to be_nil
    end
  end

  describe 'archivo del .eml' do
    let(:company) { create(:company, issuer_id_number: '3101999999') }
    let(:attachment) do
      MailReception::IncomingDocument::Attachment.new(
        clave: '506...', receptor_id_number: '3101999999', doc_type: DocType::FE, root: double('root')
      )
    end

    before do
      company
      allow(MailReception::IncomingDocument).to receive(:attachments_from).and_return([attachment])
    end

    it 'con Azure caído (transitorio), NO marca \\Seen ni intenta registrar en SAP' do
      allow(Documents::EmailArchive).to receive(:store).and_raise(Azure::BlobStorage::TransientError, 'timeout')
      allow(Sap::CompanyClient).to receive(:for)

      imap = FakeImap.new(uids: [1])
      stub_sessions(mailbox1.id => imap)

      described_class.perform_now

      expect(Sap::CompanyClient).not_to have_received(:for)
      expect(imap.marked_seen).to eq([])
    end

    it 'sin uuid válido en la compañía (configuración), NO marca \\Seen — se reintenta igual' do
      allow(Documents::EmailArchive).to receive(:store).and_raise(Documents::EmailArchive::MissingUuid, 'sin uuid')

      imap = FakeImap.new(uids: [1])
      stub_sessions(mailbox1.id => imap)

      described_class.perform_now

      expect(imap.marked_seen).to eq([])
    end

    it 'con la configuración de Azure incompleta, NO marca \\Seen' do
      allow(Documents::EmailArchive).to receive(:store)
        .and_raise(Azure::BlobStorage::MissingConfiguration, 'falta configurar')

      imap = FakeImap.new(uids: [1])
      stub_sessions(mailbox1.id => imap)

      described_class.perform_now

      expect(imap.marked_seen).to eq([])
    end
  end

  describe 'registro del mensaje receptor (después de archivar el .eml)' do
    let(:company) { create(:company, issuer_id_number: '3101999999') }
    let(:attachment) do
      MailReception::IncomingDocument::Attachment.new(
        clave: '506...', receptor_id_number: '3101999999', doc_type: DocType::FE, root: double('root')
      )
    end

    before do
      company
      allow(MailReception::IncomingDocument).to receive(:attachments_from).and_return([attachment])
      allow(Documents::EmailArchive).to receive(:store)
    end

    it 'marca \\Seen y registra en SAP cuando todo sale bien' do
      client = instance_double(Clavisco::ServiceLayer::Client)
      allow(Sap::CompanyClient).to receive(:for).with(company).and_return(client)
      reception_messages = instance_double(Sap::ReceptionMessages, create_from_document: 1)
      allow(Sap::ReceptionMessages).to receive(:new).with(client: client).and_return(reception_messages)

      imap = FakeImap.new(uids: [1])
      stub_sessions(mailbox1.id => imap)

      described_class.perform_now

      expect(reception_messages).to have_received(:create_from_document)
      expect(imap.marked_seen).to eq([1])
    end

    it 'sin configuración de SAP para la compañía, marca \\Seen (no reintenta un problema de configuración)' do
      allow(Sap::CompanyClient).to receive(:for).with(company)
        .and_raise(Sap::CompanyClient::MissingConfiguration, 'sin conexión asignada')

      imap = FakeImap.new(uids: [1])
      stub_sessions(mailbox1.id => imap)

      described_class.perform_now

      expect(imap.marked_seen).to eq([1])
    end

    it 'con la sesión de SAP vencida, NO marca \\Seen (se reintenta en la corrida siguiente)' do
      client = instance_double(Clavisco::ServiceLayer::Client)
      allow(Sap::CompanyClient).to receive(:for).with(company).and_return(client)
      reception_messages = instance_double(Sap::ReceptionMessages)
      allow(Sap::ReceptionMessages).to receive(:new).with(client: client).and_return(reception_messages)
      allow(reception_messages).to receive(:create_from_document)
        .and_raise(Clavisco::ServiceLayer::Client::SessionExpiredError, 'sesión vencida')

      imap = FakeImap.new(uids: [1])
      stub_sessions(mailbox1.id => imap)

      described_class.perform_now

      expect(imap.marked_seen).to eq([])
    end

    it 'con un rechazo de SAP (dato inválido), marca \\Seen (reintentar el mismo cuerpo no lo arregla)' do
      client = instance_double(Clavisco::ServiceLayer::Client)
      allow(Sap::CompanyClient).to receive(:for).with(company).and_return(client)
      reception_messages = instance_double(Sap::ReceptionMessages)
      allow(Sap::ReceptionMessages).to receive(:new).with(client: client).and_return(reception_messages)
      allow(reception_messages).to receive(:create_from_document)
        .and_raise(Clavisco::ServiceLayer::Client::ServiceLayerError, 'campo inválido')

      imap = FakeImap.new(uids: [1])
      stub_sessions(mailbox1.id => imap)

      described_class.perform_now

      expect(imap.marked_seen).to eq([1])
    end
  end

  describe 'valores por defecto' do
    it 'usa los defaults calculados cuando el ajuste está sin configurar' do
      set_limit('MAX_MESSAGES_PER_MAILBOX', nil)
      imap = FakeImap.new(uids: (1..10).to_a)
      stub_sessions(mailbox1.id => imap)

      described_class.perform_now

      expect(imap.marked_seen.size).to eq(described_class::DEFAULT_MAX_MESSAGES_PER_MAILBOX)
    end

    it 'usa el default cuando el ajuste guardado no es numérico' do
      set_limit('MAX_MESSAGES_PER_MAILBOX', 'no-es-un-numero')
      imap = FakeImap.new(uids: (1..10).to_a)
      stub_sessions(mailbox1.id => imap)

      described_class.perform_now

      expect(imap.marked_seen.size).to eq(described_class::DEFAULT_MAX_MESSAGES_PER_MAILBOX)
    end
  end
end
