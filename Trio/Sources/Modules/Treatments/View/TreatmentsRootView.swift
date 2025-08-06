import Charts
import CoreData
import CoreML
import LoopKitUI
import PhotosUI
import SwiftUI
import Swinject
import UIKit
import Vision

extension Treatments {
    struct RootView: BaseView {
        enum FocusedField {
            case carbs
            case fat
            case protein
            case bolus
        }

        @FocusState private var focusedField: FocusedField?

        let resolver: Resolver

        @State var state = StateModel()

        @State private var showPresetSheet = false
        @State private var autofocus: Bool = true
        @State private var calculatorDetent = PresentationDetent.large
        @State private var pushed: Bool = false
        @State private var debounce: DispatchWorkItem?

        private enum Config {
            static let dividerHeight: CGFloat = 2
            static let spacing: CGFloat = 3
        }

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        // Food Analysis States
        @State private var showConfirmDialogForBolusing = false
        @State private var showingCamera = false
        @State private var showingPhotoPicker = false
        @State private var isAnalyzingFood = false
        @State private var foodAnalysisAlert = false
        @State private var foodAnalysisMessage = ""
        @State private var showAPIKeyField = false
        @State private var tempAPIKey = ""
        @StateObject private var foodAnalyzer = FoodAnalyzer()

        private var formatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumIntegerDigits = 2
            formatter.maximumFractionDigits = 2
            return formatter
        }

        private var mealFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumIntegerDigits = 3
            formatter.maximumFractionDigits = 0
            return formatter
        }

        private var gluoseFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            if state.units == .mmolL {
                formatter.maximumIntegerDigits = 2
                formatter.maximumFractionDigits = 1
            } else {
                formatter.maximumIntegerDigits = 3
                formatter.maximumFractionDigits = 0
            }
            return formatter
        }

        private var fractionDigits: Int {
            if state.units == .mmolL {
                return 1
            } else { return 0 }
        }

        /// Handles macro input (carb, fat, protein) in a debounced fashion.
        func handleDebouncedInput() {
            debounce?.cancel()
            debounce = DispatchWorkItem { [self] in
                Task {
                    await state.updateForecasts()
                    state.insulinCalculated = await state.calculateInsulin()
                }
            }
            if let debounce = debounce {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: debounce)
            }
        }

        @ViewBuilder private func proteinAndFat() -> some View {
            HStack {
                HStack {
                    Text("Protein")
                    TextFieldWithToolBar(
                        text: $state.protein,
                        placeholder: "0",
                        keyboardType: .numberPad,
                        numberFormatter: mealFormatter,
                        showArrows: true,
                        previousTextField: { focusedField = previousField(from: .protein) },
                        nextTextField: { focusedField = nextField(from: .protein) }
                    )
                    .focused($focusedField, equals: .protein)
                    Text("g").foregroundColor(.secondary)
                }

                Divider().foregroundStyle(.primary).fontWeight(.bold).frame(width: 10)

                HStack {
                    Text("Fat")
                    TextFieldWithToolBar(
                        text: $state.fat,
                        placeholder: "0",
                        keyboardType: .numberPad,
                        numberFormatter: mealFormatter,
                        showArrows: true,
                        previousTextField: { focusedField = previousField(from: .fat) },
                        nextTextField: { focusedField = nextField(from: .fat) }
                    )
                    .focused($focusedField, equals: .fat)
                    Text("g").foregroundColor(.secondary)
                }
            }
        }

        @ViewBuilder private func carbsTextField() -> some View {
            HStack {
                Text("Carbs")
                Spacer()
                TextFieldWithToolBar(
                    text: $state.carbs,
                    placeholder: "0",
                    keyboardType: .numberPad,
                    numberFormatter: mealFormatter,
                    showArrows: true,
                    previousTextField: { focusedField = previousField(from: .carbs) },
                    nextTextField: { focusedField = nextField(from: .carbs) }
                )
                .focused($focusedField, equals: .carbs)
                .onChange(of: state.carbs) {
                    handleDebouncedInput()
                }
                Text("g").foregroundColor(.secondary)
            }
        }

        /// Determines the next field to focus on based on the current focused field.
        ///
        /// This function handles the tab order navigation between input fields,
        /// taking into account whether fat/protein fields are visible based on user settings.
        ///
        /// - Parameter current: The currently focused field
        /// - Returns: The next field that should receive focus, or nil if there is no next field
        private func nextField(from current: FocusedField) -> FocusedField? {
            // If fat/protein fields are hidden, skip them in navigation
            let showFPU = state.useFPUconversion

            switch current {
            case .fat:
                return .bolus
            case .protein:
                return .fat
            case .carbs:
                return showFPU ? .protein : .bolus
            case .bolus:
                return .carbs
            }
        }

        /// Determines the previous field to focus on based on the current focused field.
        ///
        /// This function handles the reverse tab order navigation between input fields,
        /// taking into account whether fat/protein fields are visible based on user settings.
        ///
        /// - Parameter current: The currently focused field
        /// - Returns: The previous field that should receive focus, or nil if there is no previous field
        private func previousField(from current: FocusedField) -> FocusedField? {
            let showFPU = state.useFPUconversion

            switch current {
            case .fat:
                return .protein
            case .protein:
                return .carbs
            case .carbs:
                return .bolus
            case .bolus:
                return showFPU ? .fat : .carbs
            }
        }

        var body: some View {
            ZStack(alignment: .center) {
                VStack {
                    List {
                        Section {
                            ForecastChart(state: state)
                                .padding(.vertical)
                        }.listRowBackground(Color.chart)

                        Section {
                            carbsTextField()

                            if state.useFPUconversion {
                                proteinAndFat()
                            }

                            // Time
                            HStack {
                                // Semi-hacky workaround to make sure the List renders the horizontal divider properly between the `Time` and `Note` rows within the Section
                                HStack {
                                    Text("")
                                    Image(systemName: "clock").padding(.leading, -7)
                                }

                                Spacer()
                                if !pushed {
                                    Button {
                                        pushed = true
                                    } label: { Text("Now") }.buttonStyle(.borderless).foregroundColor(.secondary)
                                        .padding(.trailing, 5)
                                } else {
                                    Button { state.date = state.date.addingTimeInterval(-15.minutes.timeInterval) }
                                    label: { Image(systemName: "minus.circle") }.tint(.blue).buttonStyle(.borderless)

                                    DatePicker(
                                        "Time",
                                        selection: $state.date,
                                        displayedComponents: [.hourAndMinute]
                                    ).controlSize(.mini)
                                        .labelsHidden()
                                        .onChange(of: state.date) { _, _ in
                                            // Trigger simulation when date changes to update forecasts for backdated carbs
                                            Task {
                                                // `updateForecasts()` does update the `simulatedDetermination` of type `Determination?` var on the main thread, so I can use this to pass its cob value into the bolus calc manager
                                                await state.updateForecasts()
                                                state.insulinCalculated = await state.calculateInsulin()
                                            }
                                        }
                                    Button {
                                        state.date = state.date.addingTimeInterval(15.minutes.timeInterval)
                                    }
                                    label: { Image(systemName: "plus.circle") }.tint(.blue).buttonStyle(.borderless)
                                }
                            }

                            // Notes
                            HStack {
                                Image(systemName: "square.and.pencil")
                                TextFieldWithToolBarString(
                                    text: $state.note,
                                    placeholder: String(localized: "Note..."),
                                    maxLength: 25
                                )
                            }
                        }.listRowBackground(Color.chart)

                        Section {
                            if state.fattyMeals || state.sweetMeals {
                                HStack(spacing: 10) {
                                    if state.fattyMeals {
                                        Toggle(isOn: $state.useFattyMealCorrectionFactor) {
                                            Text("Reduced Bolus")
                                        }
                                        .toggleStyle(RadioButtonToggleStyle())
                                        .font(.footnote)
                                        .onChange(of: state.useFattyMealCorrectionFactor) {
                                            Task {
                                                state.insulinCalculated = await state.calculateInsulin()
                                                if state.useFattyMealCorrectionFactor {
                                                    state.useSuperBolus = false
                                                }
                                            }
                                        }
                                    }
                                    if state.sweetMeals {
                                        Toggle(isOn: $state.useSuperBolus) {
                                            Text("Super Bolus")
                                        }
                                        .toggleStyle(RadioButtonToggleStyle())
                                        .font(.footnote)
                                        .onChange(of: state.useSuperBolus) {
                                            Task {
                                                state.insulinCalculated = await state.calculateInsulin()
                                                if state.useSuperBolus {
                                                    state.useFattyMealCorrectionFactor = false
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            HStack {
                                HStack {
                                    Text("Recommendation")
                                    Button(action: {
                                        state.showInfo.toggle()
                                    }, label: {
                                        Image(systemName: "info.circle")
                                    })
                                        .foregroundStyle(.blue)
                                        .buttonStyle(PlainButtonStyle())
                                }
                                Spacer()
                                Button {
                                    state.amount = state.insulinCalculated
                                } label: {
                                    HStack {
                                        Text(
                                            formatter
                                                .string(from: Double(state.insulinCalculated) as NSNumber) ?? ""
                                        )

                                        Text(
                                            String(
                                                localized:
                                                " U",
                                                comment: "Unit in number of units delivered (keep the space character!)"
                                            )
                                        ).foregroundColor(.secondary)
                                    }
                                }
                                .disabled(state.insulinCalculated == 0 || state.amount == state.insulinCalculated)
                                .buttonStyle(.bordered).padding(.trailing, -10)
                            }

                            HStack {
                                Text("Bolus")
                                Spacer()
                                TextFieldWithToolBar(
                                    text: $state.amount,
                                    placeholder: "0",
                                    textColor: colorScheme == .dark ? .white : .blue,
                                    maxLength: 5,
                                    numberFormatter: formatter,
                                    showArrows: true,
                                    previousTextField: { focusedField = previousField(from: .bolus) },
                                    nextTextField: { focusedField = nextField(from: .bolus) }
                                ).focused($focusedField, equals: .bolus)
                                    .onChange(of: state.amount) {
                                        Task {
                                            await state.updateForecasts()
                                        }
                                    }
                                Text(" U").foregroundColor(.secondary)
                            }

                            HStack {
                                Text("External Insulin")
                                Spacer()
                                Toggle("", isOn: $state.externalInsulin).toggleStyle(CheckboxToggleStyle())
                            }
                        }.listRowBackground(Color.chart)

                        treatmentButton

                        // Food Analysis Camera Section
                        Section {
                            VStack(spacing: 12) {
                                Button(action: {
                                    print("🔴 Take Photo button pressed")
                                    guard !isAnalyzingFood else { return }
                                    if foodAnalyzer.hasValidAPIKey {
                                        // Ensure photo picker is closed first
                                        showingPhotoPicker = false
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                            self.showingCamera = true
                                        }
                                    } else {
                                        showAPIKeyField = true
                                    }
                                }) {
                                    HStack {
                                        Image(systemName: "camera.fill")
                                        Text("Take Photo")
                                    }
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(foodAnalyzer.hasValidAPIKey ? Color.green : Color.gray)
                                    .cornerRadius(10)
                                }
                                .disabled(isAnalyzingFood)
                                .buttonStyle(.plain)

                                Button(action: {
                                    print("🔵 From Gallery button pressed")
                                    guard !isAnalyzingFood else { return }
                                    if foodAnalyzer.hasValidAPIKey {
                                        // Ensure camera is closed first
                                        showingCamera = false
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                            self.showingPhotoPicker = true
                                        }
                                    } else {
                                        showAPIKeyField = true
                                    }
                                }) {
                                    HStack {
                                        Image(systemName: "photo.fill")
                                        Text("From Gallery")
                                    }
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(foodAnalyzer.hasValidAPIKey ? Color.blue : Color.gray)
                                    .cornerRadius(10)
                                }
                                .disabled(isAnalyzingFood)
                                .buttonStyle(.plain)
                            }

                            if isAnalyzingFood {
                                HStack {
                                    ProgressView()
                                        .scaleEffect(0.8)
                                    Text("Analyzing food...")
                                        .foregroundColor(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 8)
                            }

                            // API Key Configuration Section
                            VStack(spacing: 8) {
                                Button(action: {
                                    withAnimation(.easeInOut(duration: 0.3)) {
                                        showAPIKeyField.toggle()
                                    }
                                    if showAPIKeyField {
                                        tempAPIKey = foodAnalyzer.getAPIKey() ?? ""
                                    }
                                }) {
                                    HStack {
                                        Image(systemName: "key.fill")
                                        Text(foodAnalyzer.hasValidAPIKey ? "Update API Key" : "Set OpenAI API Key")
                                        Spacer()
                                        Image(systemName: showAPIKeyField ? "chevron.up" : "chevron.down")
                                    }
                                    .foregroundColor(foodAnalyzer.hasValidAPIKey ? .green : .orange)
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)

                                if showAPIKeyField {
                                    VStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text("OpenAI API Key")
                                                .font(.caption)
                                                .foregroundColor(.secondary)

                                            SecureField("sk-...", text: $tempAPIKey)
                                                .textFieldStyle(.roundedBorder)
                                                .autocapitalization(.none)
                                                .autocorrectionDisabled()
                                                .textContentType(.password)
                                                .submitLabel(.done)
                                                .onSubmit {
                                                    if !tempAPIKey.isEmpty {
                                                        foodAnalyzer.saveAPIKey(tempAPIKey)
                                                        withAnimation(.easeInOut(duration: 0.3)) {
                                                            showAPIKeyField = false
                                                        }
                                                        tempAPIKey = ""
                                                    }
                                                }
                                        }

                                        HStack {
                                            Button("Cancel") {
                                                withAnimation(.easeInOut(duration: 0.3)) {
                                                    showAPIKeyField = false
                                                }
                                                tempAPIKey = ""
                                                // Dismiss keyboard
                                                UIApplication.shared.sendAction(
                                                    #selector(UIResponder.resignFirstResponder),
                                                    to: nil,
                                                    from: nil,
                                                    for: nil
                                                )
                                            }
                                            .foregroundColor(.secondary)

                                            Spacer()

                                            Button("Save") {
                                                foodAnalyzer.saveAPIKey(tempAPIKey)
                                                withAnimation(.easeInOut(duration: 0.3)) {
                                                    showAPIKeyField = false
                                                }
                                                tempAPIKey = ""
                                                // Dismiss keyboard
                                                UIApplication.shared.sendAction(
                                                    #selector(UIResponder.resignFirstResponder),
                                                    to: nil,
                                                    from: nil,
                                                    for: nil
                                                )
                                            }
                                            .disabled(tempAPIKey.isEmpty)
                                            .foregroundColor(.blue)
                                            .fontWeight(.semibold)
                                        }

                                        if foodAnalyzer.hasValidAPIKey {
                                            Button("Remove API Key") {
                                                foodAnalyzer.removeAPIKey()
                                                withAnimation(.easeInOut(duration: 0.3)) {
                                                    showAPIKeyField = false
                                                }
                                                tempAPIKey = ""
                                                // Dismiss keyboard
                                                UIApplication.shared.sendAction(
                                                    #selector(UIResponder.resignFirstResponder),
                                                    to: nil,
                                                    from: nil,
                                                    for: nil
                                                )
                                            }
                                            .foregroundColor(.red)
                                        }

                                        Text("Your API key is stored securely in the device keychain and never shared.")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .multilineTextAlignment(.center)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .padding(.vertical, 8)
                                    .transition(.opacity.combined(with: .scale))
                                }
                            }
                        }
                        .listRowBackground(Color.chart)
                    }
                    .listSectionSpacing(sectionSpacing)
                }
                .blur(radius: state.isAwaitingDeterminationResult ? 5 : 0)

                if state.isAwaitingDeterminationResult {
                    CustomProgressView(text: progressText.displayName)
                }
            }
            .padding(.top)
            .ignoresSafeArea(edges: .top)
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .blur(radius: state.showInfo ? 3 : 0)
            .navigationTitle("Treatments")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        state.hideModal()
                    } label: {
                        Text("Close")
                    }
                }
                if state.displayPresets {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: {
                            showPresetSheet = true
                        }, label: {
                            HStack {
                                Text("Presets")
                                Image(systemName: "plus")
                            }
                        })
                    }
                }
            })
            .onAppear {
                configureView {
                    state.isActive = true
                    Task { @MainActor in
                        state.insulinCalculated = await state.calculateInsulin()
                    }
                }
            }
            .onDisappear {
                state.isActive = false
                state.addButtonPressed = false

                // Cancel all Combine subscriptions and unregister State from broadcaster
                state.cleanupTreatmentState()
            }
            .sheet(isPresented: $state.showInfo) {
                PopupView(state: state)
            }
            .sheet(isPresented: $showPresetSheet, onDismiss: {
                showPresetSheet = false
            }) {
                MealPresetView(state: state)
            }
            .sheet(isPresented: $showingCamera) {
                CameraImagePicker { image in
                    showingCamera = false // Explicitly close camera
                    if let image = image {
                        analyzeFoodImage(image)
                    }
                }
            }
            .photosPicker(
                isPresented: $showingPhotoPicker,
                selection: Binding<PhotosPickerItem?>(
                    get: { nil },
                    set: { newItem in
                        showingPhotoPicker = false // Explicitly close picker
                        if let newItem = newItem {
                            Task {
                                if let data = try? await newItem.loadTransferable(type: Data.self),
                                   let image = UIImage(data: data)
                                {
                                    DispatchQueue.main.async {
                                        self.analyzeFoodImage(image)
                                    }
                                }
                            }
                        }
                    }
                ),
                matching: .images
            )
            .alert("Food Analysis", isPresented: $foodAnalysisAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(foodAnalysisMessage)
            }
            .alert("Error while processing Treatment", isPresented: $state.showDeterminationFailureAlert) {
                Button("OK", role: .cancel) {
                    state.hideModal()
                }
            } message: {
                Text("\(state.determinationFailureMessage)")
            }
        }

        // MARK: - Food Analysis Methods

        private func analyzeFoodImage(_ image: UIImage) {
            isAnalyzingFood = true

            foodAnalyzer.analyzeFood(image: image) { result in
                DispatchQueue.main.async {
                    isAnalyzingFood = false

                    switch result {
                    case let .success(analysisResult):
                        // Update the treatment fields with analyzed values - convert Double to Decimal
                        state.carbs = Decimal(analysisResult.carbohydrates)
                        state.fat = Decimal(analysisResult.fat)
                        state.protein = Decimal(analysisResult.protein)

                        // Add food description to notes if available
                        if !analysisResult.foodDescription.isEmpty {
                            state.note = analysisResult.foodDescription
                        }

                        // Trigger calculation updates
                        handleDebouncedInput()

                        foodAnalysisMessage =
                            "Successfully analyzed: \(analysisResult.foodDescription)\nCarbs: \(analysisResult.carbohydrates)g, Fat: \(analysisResult.fat)g, Protein: \(analysisResult.protein)g"
                        foodAnalysisAlert = false

                    case let .failure(error):
                        foodAnalysisMessage = "Failed to analyze food: \(error.localizedDescription)"
                        foodAnalysisAlert = true
                    }
                }
            }
        }

        var progressText: ProgressText {
            switch (state.amount > 0, state.carbs > 0) {
            case (true, true):
                return .updatingIOBandCOB
            case (false, true):
                return .updatingCOB
            case (true, false):
                return .updatingIOB
            default:
                return .updatingTreatments
            }
        }

        private var bolusWarning: (shouldConfirm: Bool, warningMessage: String, color: Color) {
            let isGlucoseVeryLow = state.currentBG < 54
            let isForecastVeryLow = state.minPredBG < 54

            // Only warn when enacting a bolus via pump
            guard !state.externalInsulin, state.amount > 0 else {
                return (false, "", .primary)
            }

            let warningMessage = isGlucoseVeryLow ? String(localized: "Glucose is very low.") :
                isForecastVeryLow ? String(localized: "Glucose forecast is very low.") :
                ""

            let warningColor: Color = isGlucoseVeryLow ? .red : colorScheme == .dark ? .orange : .accentColor

            let shouldConfirm = state.confirmBolus && (isGlucoseVeryLow || isForecastVeryLow)

            return (shouldConfirm, warningMessage, warningColor)
        }

        var treatmentButton: some View {
            var treatmentButtonBackground = Color(.systemBlue)
            if limitExceeded {
                treatmentButtonBackground = Color(.systemRed)
            } else if disableTaskButton {
                treatmentButtonBackground = Color(.systemGray)
            }

            return Section {
                Button {
                    if bolusWarning.shouldConfirm {
                        showConfirmDialogForBolusing = true
                    } else {
                        state.invokeTreatmentsTask()
                    }
                } label: {
                    HStack {
                        if state.isBolusInProgress && state.amount > 0 &&
                            !state.externalInsulin && (state.carbs == 0 || state.fat == 0 || state.protein == 0)
                        {
                            ProgressView()
                        }
                        taskButtonLabel
                    }
                    .font(.headline)
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 35)
                }
                .disabled(disableTaskButton)
                .listRowBackground(treatmentButtonBackground)
                .shadow(radius: 3)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .confirmationDialog(
                    bolusWarning.warningMessage + " Bolus \(state.amount.description) U?",
                    isPresented: $showConfirmDialogForBolusing,
                    titleVisibility: .visible
                ) {
                    Button("Cancel", role: .cancel) {}
                    Button(
                        bolusWarning.warningMessage.isEmpty ? "Enact Bolus" : "Ignore Warning and Enact Bolus",
                        role: bolusWarning.warningMessage.isEmpty ? nil : .destructive
                    ) {
                        state.invokeTreatmentsTask()
                    }
                }
            } header: {
                if !bolusWarning.warningMessage.isEmpty {
                    Text(bolusWarning.warningMessage)
                        .textCase(nil)
                        .font(.subheadline)
                        .foregroundColor(bolusWarning.color)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, -22)
                }
            }
        }

        private var taskButtonLabel: some View {
            if pumpBolusLimitExceeded {
                return Text("Max Bolus of \(state.maxBolus.description) U Exceeded")
            } else if externalBolusLimitExceeded {
                return Text("Max External Bolus of \(state.maxExternal.description) U Exceeded")
            } else if carbLimitExceeded {
                return Text("Max Carbs of \(state.maxCarbs.description) g Exceeded")
            } else if fatLimitExceeded {
                return Text("Max Fat of \(state.maxFat.description) g Exceeded")
            } else if proteinLimitExceeded {
                return Text("Max Protein of \(state.maxProtein.description) g Exceeded")
            }

            let hasInsulin = state.amount > 0
            let hasCarbs = state.carbs > 0
            let hasFatOrProtein = state.fat > 0 || state.protein > 0
            let bolusString = state.externalInsulin ? String(localized: "External Insulin") : String(localized: "Enact Bolus")

            if state.isBolusInProgress && hasInsulin && !state.externalInsulin && (!hasCarbs || !hasFatOrProtein) {
                return Text("Bolus In Progress...")
            }

            switch (hasInsulin, hasCarbs, hasFatOrProtein) {
            case (true, true, true):
                return Text("Log Meal and \(bolusString)")
            case (true, true, false):
                return Text("Log Carbs and \(bolusString)")
            case (true, false, true):
                return Text("Log FPU and \(bolusString)")
            case (true, false, false):
                return Text(state.externalInsulin ? "Log External Insulin" : "Enact Bolus")
            case (false, true, true):
                return Text("Log Meal")
            case (false, true, false):
                return Text("Log Carbs")
            case (false, false, true):
                return Text("Log FPU")
            default:
                return Text("Continue Without Treatment")
            }
        }

        private var pumpBolusLimitExceeded: Bool {
            !state.externalInsulin && state.amount > state.maxBolus
        }

        private var externalBolusLimitExceeded: Bool {
            state.externalInsulin && state.amount > state.maxExternal
        }

        private var carbLimitExceeded: Bool {
            state.carbs > state.maxCarbs
        }

        private var fatLimitExceeded: Bool {
            state.fat > state.maxFat
        }

        private var proteinLimitExceeded: Bool {
            state.protein > state.maxProtein
        }

        private var limitExceeded: Bool {
            pumpBolusLimitExceeded || externalBolusLimitExceeded || carbLimitExceeded || fatLimitExceeded || proteinLimitExceeded
        }

        private var disableTaskButton: Bool {
            (
                state.isBolusInProgress && state
                    .amount > 0 && !state.externalInsulin && (state.carbs == 0 || state.fat == 0 || state.protein == 0)
            ) || state
                .addButtonPressed || limitExceeded
        }
    }

    struct DividerDouble: View {
        var body: some View {
            VStack(spacing: 2) {
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(.gray.opacity(0.65))
                Rectangle()
                    .frame(height: 1)
                    .foregroundColor(.gray.opacity(0.65))
            }
            .frame(height: 4)
            .padding(.vertical)
        }
    }

    struct DividerCustom: View {
        var body: some View {
            Rectangle()
                .frame(height: 1)
                .foregroundColor(.gray.opacity(0.65))
                .padding(.vertical)
        }
    }
}

// MARK: - Food Analysis Result

struct FoodAnalysisResult {
    let foodDescription: String
    let fat: Double
    let carbohydrates: Double
    let protein: Double
}

// MARK: - Food Analyzer Class

class FoodAnalyzer: ObservableObject {
    @Published var hasValidAPIKey: Bool = false

    private let keychainKey = "OpenAI_API_Key"

    init() {
        checkAPIKeyStatus()
    }

    // Check if API key exists and update status
    private func checkAPIKeyStatus() {
        hasValidAPIKey = getAPIKey() != nil
    }

    // Save API key to keychain
    func saveAPIKey(_ apiKey: String) {
        print("🔑 Attempting to save API key...")
        guard !apiKey.isEmpty else {
            print("❌ API key is empty")
            return
        }

        print("🔑 API key length: \(apiKey.count)")

        guard let data = apiKey.data(using: .utf8) else {
            print("❌ Failed to convert API key to data")
            return
        }

        print("🔑 API key converted to data successfully")

        // First, delete any existing item
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "FoodAnalyzer",
            kSecAttrAccount as String: keychainKey
        ]

        let deleteStatus = SecItemDelete(deleteQuery as CFDictionary)
        print("🔑 Delete existing item status: \(deleteStatus) (this is OK if item doesn't exist)")

        // Add new item
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "FoodAnalyzer",
            kSecAttrAccount as String: keychainKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]

        print("🔑 Attempting to add item to keychain...")
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        print("🔑 Keychain add status: \(status)")

        let success = (status == errSecSuccess)
        print("🔑 Save successful: \(success)")

        DispatchQueue.main.async {
            self.hasValidAPIKey = success
            print("🔑 Updated hasValidAPIKey to: \(success)")
        }
    }

    // Get API key from keychain
    func getAPIKey() -> String? {
        print("🔍 Attempting to retrieve API key...")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "FoodAnalyzer",
            kSecAttrAccount as String: keychainKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        print("🔍 Keychain read status: \(status)")

        guard status == errSecSuccess else {
            print("❌ Failed to retrieve API key, status: \(status)")
            return nil
        }

        guard let data = item as? Data else {
            print("❌ Retrieved item is not Data")
            return nil
        }

        guard let apiKey = String(data: data, encoding: .utf8) else {
            print("❌ Failed to convert data to string")
            return nil
        }

        print("✅ API key retrieved successfully, length: \(apiKey.count)")
        return apiKey
    }

    // Remove API key from keychain
    func removeAPIKey() {
        print("🗑️ Attempting to remove API key...")

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "FoodAnalyzer",
            kSecAttrAccount as String: keychainKey
        ]

        let status = SecItemDelete(query as CFDictionary)
        print("🗑️ Keychain delete status: \(status)")

        DispatchQueue.main.async {
            self.hasValidAPIKey = false
            print("🗑️ Updated hasValidAPIKey to: false")
        }
    }

    // Analyze food image using OpenAI Vision API
    func analyzeFood(image: UIImage, completion: @escaping (Result<FoodAnalysisResult, Error>) -> Void) {
        guard let apiKey = getAPIKey() else {
            completion(.failure(NSError(
                domain: "APIKeyError",
                code: 0,
                userInfo: [NSLocalizedDescriptionKey: "No API key found. Please set your OpenAI API key."]
            )))
            return
        }

        // Convert image to base64
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            completion(.failure(NSError(
                domain: "ImageError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not convert image to data"]
            )))
            return
        }

        let base64Image = imageData.base64EncodedString()

        // OpenAI API configuration
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Create the request payload
        let payload: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": """
                            Please analyze this food image and provide nutritional information. 
                            Respond ONLY in this exact JSON format with no additional text:
                            {
                                "foodDescription": "brief description of the food",
                                "fat": 0.0,
                                "carbohydrates": 0.0,
                                "protein": 0.0
                            }

                            Provide values in grams for a typical serving size shown in the image. 
                            If multiple food items are visible, provide totals for the entire meal.
                            """
                        ],
                        [
                            "type": "image_url",
                            "image_url": [
                                "url": "data:image/jpeg;base64,\(base64Image)"
                            ]
                        ]
                    ]
                ]
            ],
            "max_tokens": 300
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            completion(.failure(error))
            return
        }

        // Make the API request
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("❌ Network error: \(error.localizedDescription)")
                completion(.failure(error))
                return
            }

            // Check HTTP response
            if let httpResponse = response as? HTTPURLResponse {
                print("🌐 HTTP Status Code: \(httpResponse.statusCode)")
                print("🌐 HTTP Headers: \(httpResponse.allHeaderFields)")
            }

            guard let data = data else {
                print("❌ No data received")
                completion(.failure(NSError(
                    domain: "APIError",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "No data received"]
                )))
                return
            }

            print("✅ Received \(data.count) bytes from OpenAI")

            // Show raw response as string first
            let rawResponse = String(data: data, encoding: .utf8) ?? "Unable to decode as UTF-8"
            print("🔍 Raw response (first 500 chars): \(String(rawResponse.prefix(500)))")

            // Check if response starts with expected JSON
            if !rawResponse.hasPrefix("{"), !rawResponse.hasPrefix("[") {
                print("❌ Response doesn't start with JSON. Starts with: '\(String(rawResponse.prefix(20)))'")
                completion(.failure(NSError(
                    domain: "APIError",
                    code: 11,
                    userInfo: [NSLocalizedDescriptionKey: "Response is not JSON format. Response: \(rawResponse)"]
                )))
                return
            }

            // Parse the response
            do {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                print("✅ Successfully parsed top-level JSON")

                guard let json = json else {
                    print("❌ JSON is not a dictionary")
                    completion(.failure(NSError(
                        domain: "APIError",
                        code: 12,
                        userInfo: [NSLocalizedDescriptionKey: "JSON is not a dictionary"]
                    )))
                    return
                }

                print("🔍 JSON keys: \(Array(json.keys))")

                // Check for API errors first
                if let error = json["error"] as? [String: Any] {
                    print("❌ OpenAI API Error: \(error)")
                    let message = error["message"] as? String ?? "Unknown API error"
                    let type = error["type"] as? String ?? "unknown"
                    completion(.failure(NSError(
                        domain: "OpenAIError",
                        code: 13,
                        userInfo: [NSLocalizedDescriptionKey: "OpenAI Error (\(type)): \(message)"]
                    )))
                    return
                }

                guard let choices = json["choices"] as? [[String: Any]] else {
                    print("❌ No 'choices' array in response")
                    completion(.failure(NSError(
                        domain: "APIError",
                        code: 14,
                        userInfo: [NSLocalizedDescriptionKey: "No choices in API response"]
                    )))
                    return
                }

                guard let firstChoice = choices.first else {
                    print("❌ Choices array is empty")
                    completion(.failure(NSError(
                        domain: "APIError",
                        code: 15,
                        userInfo: [NSLocalizedDescriptionKey: "Empty choices array"]
                    )))
                    return
                }

                print("🔍 First choice keys: \(Array(firstChoice.keys))")

                guard let message = firstChoice["message"] as? [String: Any] else {
                    print("❌ No 'message' in first choice")
                    completion(.failure(NSError(
                        domain: "APIError",
                        code: 16,
                        userInfo: [NSLocalizedDescriptionKey: "No message in choice"]
                    )))
                    return
                }

                print("🔍 Message keys: \(Array(message.keys))")

                guard let content = message["content"] as? String else {
                    print("❌ No 'content' in message")
                    completion(.failure(NSError(
                        domain: "APIError",
                        code: 17,
                        userInfo: [NSLocalizedDescriptionKey: "No content in message"]
                    )))
                    return
                }

                print("🔍 Raw content from OpenAI: '\(content)'")

                // Clean the content - remove markdown code blocks if present
                let cleanedContent = content
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "```json", with: "")
                    .replacingOccurrences(of: "```", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                print("🔍 Cleaned content: '\(cleanedContent)'")

                // Validate that cleaned content looks like JSON
                if !cleanedContent.hasPrefix("{") {
                    print("❌ Cleaned content doesn't start with '{'. Starts with: '\(String(cleanedContent.prefix(20)))'")
                    completion(.failure(NSError(
                        domain: "ParseError",
                        code: 18,
                        userInfo: [NSLocalizedDescriptionKey: "Content is not JSON format: \(cleanedContent)"]
                    )))
                    return
                }

                // Parse the JSON content from OpenAI response
                guard let contentData = cleanedContent.data(using: .utf8) else {
                    print("❌ Failed to convert cleaned content to data")
                    completion(.failure(NSError(
                        domain: "ParseError",
                        code: 19,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to convert content to data"]
                    )))
                    return
                }

                do {
                    guard let nutritionJson = try JSONSerialization.jsonObject(with: contentData) as? [String: Any] else {
                        print("❌ Content JSON is not a dictionary")
                        completion(.failure(NSError(
                            domain: "ParseError",
                            code: 20,
                            userInfo: [NSLocalizedDescriptionKey: "Content JSON is not a dictionary"]
                        )))
                        return
                    }

                    print("🔍 Parsed nutrition JSON keys: \(Array(nutritionJson.keys))")
                    print("🔍 Full nutrition JSON: \(nutritionJson)")

                    guard let foodDescription = nutritionJson["foodDescription"] as? String,
                          let fat = nutritionJson["fat"] as? Double,
                          let carbohydrates = nutritionJson["carbohydrates"] as? Double,
                          let protein = nutritionJson["protein"] as? Double
                    else {
                        print("❌ Missing required fields in nutrition JSON")
                        print("🔍 foodDescription: \(nutritionJson["foodDescription"] ?? "missing")")
                        print("🔍 fat: \(nutritionJson["fat"] ?? "missing")")
                        print("🔍 carbohydrates: \(nutritionJson["carbohydrates"] ?? "missing")")
                        print("🔍 protein: \(nutritionJson["protein"] ?? "missing")")
                        completion(.failure(NSError(
                            domain: "ParseError",
                            code: 21,
                            userInfo: [NSLocalizedDescriptionKey: "Missing required nutrition fields"]
                        )))
                        return
                    }

                    let result = FoodAnalysisResult(
                        foodDescription: foodDescription,
                        fat: fat,
                        carbohydrates: carbohydrates,
                        protein: protein
                    )
                    print("✅ Successfully parsed food analysis: \(foodDescription)")
                    completion(.success(result))

                } catch {
                    print("❌ JSON parsing error for content: \(error)")
                    completion(.failure(NSError(
                        domain: "ParseError",
                        code: 22,
                        userInfo: [
                            NSLocalizedDescriptionKey: "JSON parsing failed: \(error.localizedDescription). Content: \(cleanedContent)"
                        ]
                    )))
                }

            } catch {
                print("❌ Top-level JSON serialization error: \(error)")
                print("🔍 Raw data (hex): \(data.map { String(format: "%02x", $0) }.joined())")
                completion(.failure(NSError(
                    domain: "APIError",
                    code: 23,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to parse API response as JSON: \(error.localizedDescription)"]
                )))
            }
        }.resume()
    }
}

// MARK: - Camera Image Picker (Camera Only)

struct CameraImagePicker: UIViewControllerRepresentable {
    @Environment(\.presentationMode) var presentationMode
    var onImageSelected: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_: UIImagePickerController, context _: Context) {}

    func makeCoordinator() -> CameraCoordinator {
        CameraCoordinator(self)
    }

    class CameraCoordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraImagePicker

        init(_ parent: CameraImagePicker) {
            self.parent = parent
        }

        func imagePickerController(
            _: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            print("📸 Camera: Image selected")
            let image = info[.originalImage] as? UIImage

            // Dismiss first, then callback
            parent.presentationMode.wrappedValue.dismiss()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.parent.onImageSelected(image)
            }
        }

        func imagePickerControllerDidCancel(_: UIImagePickerController) {
            print("📸 Camera: Cancelled")

            // Dismiss first, then callback with nil
            parent.presentationMode.wrappedValue.dismiss()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.parent.onImageSelected(nil)
            }
        }
    }
}
